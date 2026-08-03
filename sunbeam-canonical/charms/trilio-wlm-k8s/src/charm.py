#!/usr/bin/env python3
"""TrilioVault WorkloadManager Kubernetes charm for Sunbeam Canonical OpenStack.

Manages four WLM microservices via Pebble inside the trilio-wlm container:
  wlm-api, wlm-workloads, wlm-scheduler, wlm-cron (leader-only singleton).

Also embeds a co-located Dynamic Mount Service (DMS) server as a second
container (trilio-dms) in the same pod — one DMS instance per WLM replica,
1:1, rather than a single cluster-wide trilio-dms-k8s app. This removes the
old cross-pod hostPath+podAffinity mount-sharing mechanism entirely: since
both containers are guaranteed co-located in the same pod, they can share
an ordinary emptyDir volume instead, with no node pinning required — WLM
can scale to N replicas and each one carries its own DMS. A second,
independent DMS instance also runs on every compute node, managed by the
trilio-data-mover-sunbeam machine charm (unrelated to this control-plane one).

Tested against Caracal (OpenStack 2024.1) on Sunbeam.

Relation interface notes (Sunbeam Caracal):
  - database: mysql_client interface — provider writes into its *application* databag.
    Keys: endpoints, username, password, database.
  - amqp: rabbitmq interface — requirer writes username/vhost to its *app* databag
    (leader only); provider responds with hostname/password in its *app* databag.
  - identity-service: keystone interface — requirer writes service-endpoints (JSON)
    and region to its *app* databag (leader only); provider responds with service-host,
    service-port, service-protocol, service-credentials (Juju secret) in its *app*
    databag.
  - ingress-internal / ingress-public: traefik_k8s v2 ingress interface.
    Requirer writes a JSON blob under "data" key in the app databag.
"""

import json
import logging
import os
import socket

import jinja2
import ops
from lightkube import Client
from lightkube.resources.apps_v1 import StatefulSet
from lightkube.types import PatchType

logger = logging.getLogger(__name__)

CONTAINER = "trilio-wlm"
DMS_CONTAINER = "trilio-dms"
CONFIG_PATH = "/etc/triliovault-wlm/triliovault-wlm.conf"
API_PASTE_PATH = "/etc/triliovault-wlm/api-paste.ini"
WLM_LOGGING_CONF_PATH = "/etc/triliovault-wlm/wlm_logging.conf"
DMS_CLIENT_CONF = "/etc/triliovault-dms/client.conf"
DMS_SERVER_CONF = "/etc/triliovault-dms/server.conf"
DMS_SERVER_LOG_FILE = "/var/log/triliovault/trilio-dms-server.log"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
OBJECT_STORE_LOGGING_CONF_PATH = "/etc/triliovault-object-store/object_store_logging.conf"
# DMS performs the actual `mount` syscall for NFS/S3 backup targets inside its
# own container. Sharing a volume across containers isn't sufficient on its
# own for one container's mount() calls to become visible in a sibling's mount
# namespace — Kubernetes still requires explicit mountPropagation regardless of
# volume type. Since trilio-dms is co-located with trilio-wlm in the same pod
# (guaranteed, not just scheduled that way), an ordinary emptyDir volume works
# here — no hostPath, no podAffinity, no node pinning (see
# _patch_shared_vault_mount).
VAULT_MOUNTS_PATH = "/var/triliovault-mounts"
LOG_DIR = "/var/log/triliovault"
CA_BUNDLE_PATH = "/usr/local/share/ca-certificates/ca-bundle.crt"
TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")

# The api-paste.ini shipped by the WLM deb package contains legacy
# %SERVICE_TENANT_NAME% / %SERVICE_USER% / %SERVICE_PASSWORD% placeholders.
# Python's configparser treats % as an interpolation prefix and raises
# InterpolationSyntaxError when it sees %S (not %(key)s format), crashing
# wlm-api on startup. The charm overwrites the file with this clean version
# that removes the deprecated auth fields (keystonemiddleware reads credentials
# from [keystone_authtoken] in the main config anyway).

# Port confirmed from `openstack endpoint list` on RHOSO18 (consistent across all
# OpenStack distributions): triliovault-wlm-internal.svc:8781
# Must be explicit via osapi_workloads_listen_port so the binary binds here.
WLM_PORT = 8781
# Service type/name confirmed from `openstack endpoint list` — same on all platforms:
#   Service Name=TrilioVaultWLM  Service Type=workloads
WLM_SERVICE_TYPE = "workloads"
WLM_SERVICE_NAME = "TrilioVaultWLM"
# Endpoint path template matching production WLM endpoint format.
WLM_ENDPOINT_TEMPLATE = "{}/v1/$(tenant_id)s"
# Traefik ingress model+name — Traefik constructs the path as /{model}-{name}.
# Setting model="trilio" and name="wlm" gives path /trilio-wlm (no openstack- prefix).
WLM_INGRESS_MODEL = "trilio"
WLM_INGRESS_NAME = "wlm"


class TrilioWlmK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_wlm_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.trilio_dms_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.leader_elected, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._on_upgrade_charm)
        for rel in ("database", "amqp", "amqp_dms", "identity_service"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_changed"), self._configure
            )
        self.framework.observe(self.on.wlm_service_relation_joined, self._on_wlm_service_joined)
        for rel in ("ingress_internal", "ingress_public"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_joined"), self._on_ingress_relation_joined
            )
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_changed"), self._on_ingress_relation_changed
            )
        self.framework.observe(self.on.amqp_relation_joined, self._on_amqp_relation_joined)
        self.framework.observe(self.on.amqp_dms_relation_joined, self._on_amqp_dms_relation_joined)
        self.framework.observe(self.on.database_relation_joined, self._on_database_relation_joined)
        self.framework.observe(
            self.on.identity_service_relation_joined,
            self._on_identity_service_relation_joined,
        )
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._configure
        )
        self.framework.observe(
            self.on.create_cloud_admin_trust_action, self._on_create_trust_action
        )
        self.framework.observe(self.on.create_license_action, self._on_create_license_action)

    # --- event handlers ---

    def _on_pebble_ready(self, event):
        self._configure(event)

    def _on_wlm_service_joined(self, event):
        if self.unit.is_leader():
            self._publish_wlm_service_data()

    def _on_ingress_relation_joined(self, event):
        self._publish_ingress(event.relation)

    def _on_ingress_relation_changed(self, event):
        self._register_keystone_service()

    def _on_upgrade_charm(self, event):
        """Re-publish ingress data on charm upgrade so Traefik picks up any format changes."""
        for rel_name in ("ingress-internal", "ingress-public"):
            rel = self.model.get_relation(rel_name)
            if rel:
                self._publish_ingress(rel)
        self._configure(event)

    def _on_amqp_relation_joined(self, event):
        """Write rabbitmq requirer credentials so rabbitmq-k8s provisions the user/vhost."""
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "workloadmgr"
            event.relation.data[self.app]["vhost"] = "workloadmgr"

    def _on_amqp_dms_relation_joined(self, event):
        """Second amqp relation for the WLM-side DMS client and embedded DMS server.

        Both WLM oslo.messaging and WLM DMS use the same `workloadmgr` vhost —
        matching the RHOSO18 pattern where WLM_RABBIT_VHOST=workloadmgr. Requesting
        the same username/vhost here is idempotent — rabbitmq-k8s returns the same
        already-provisioned user/password.
        """
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "workloadmgr"
            event.relation.data[self.app]["vhost"] = "workloadmgr"

    def _on_database_relation_joined(self, event):
        """Write mysql requirer database name so mysql-k8s provisions the database."""
        if self.unit.is_leader():
            event.relation.data[self.app]["database"] = "workloadmgr"

    def _on_identity_service_relation_joined(self, event):
        """Write keystone service registration so keystone creates the service endpoints."""
        self._register_keystone_service()

    def _on_create_trust_action(self, event):
        """Action: create trust between WLM service user and Cloud Admin.

        Must be run once after deployment before TrilioVault can perform backups.
        Runs 'workloadmgr trust-create' inside the workload container using the
        admin credentials supplied as action params.

        cloud-admin-user-id/cloud-admin-project-id (needed for
        backup-target-create/workload-create to find this trust — see
        _write_config) are populated automatically from the identity-service
        relation's admin-user-id/admin-project-id fields (matching how the
        older charm-trilio-wlm reactive charm read identity_service.get(
        'admin_user_id')/'admin_project_id') — no manual `juju config` step
        needed. Charm config still overrides this if explicitly set (e.g. for
        a differently-scoped cloud-admin identity).

        One prerequisite this action does NOT set up for you: the admin user
        must hold the "admin" role at *system* scope, not just on its own
        project/domain — a fresh Sunbeam admin user only has domain-scoped
        admin, which isn't enough to act as a true cross-domain cloud admin:
          openstack role add --user admin --user-domain admin_domain \\
            --system all admin
        """
        if not self.unit.is_leader():
            event.fail("Run this action on the leader unit only")
            return
        identity = self._identity_data()
        if not identity:
            event.fail("identity-service relation not ready — wait for charm to reach active status")
            return
        container = self.unit.get_container(CONTAINER)
        if not container.can_connect():
            event.fail("Workload container not ready")
            return
        auth_url = (
            f"{identity['service_protocol']}://"
            f"{identity['service_host']}:{identity['service_port']}/v3"
        )
        # setsid detaches the process from Pebble's controlling terminal so that
        # workloadmgr's cliff/cmd2 cannot open /dev/tty and skips curses init.
        # --endpoint-type admin uses the admin endpoint URL (http://trilio-wlm-k8s:8781/v1/...)
        # which routes directly to WLM API without the Traefik path prefix issue.
        cmd = [
            "setsid",
            "workloadmgr",
            "--os-username", "admin",
            "--os-password", event.params["password"],
            "--os-auth-url", auth_url,
            "--os-user-domain-name", event.params.get("user-domain-name", "admin_domain"),
            "--os-project-name", event.params.get("project-name", "admin"),
            "--os-project-domain-name", event.params.get("project-domain-name", "admin_domain"),
            "--os-region-name", self.config.get("region", "RegionOne"),
            "--endpoint-type", "admin",
            # Role name is case-sensitive and must match the actual Keystone
            # role exactly ("admin", lowercase) — "Admin" silently fails with
            # "Invalid roles ['Admin']" since Keystone has no such role.
            "trust-create", "--is_cloud_trust", "True", "admin",
        ]
        try:
            out, err = container.exec(cmd, environment={"TERM": "xterm"}).wait_output()
            logger.info("trust-create output: %s", out)
            event.set_results({"result": "Cloud admin trust created successfully"})
        except Exception as e:
            event.fail(f"trust-create failed: {e}")

    def _on_create_license_action(self, event):
        """Action: apply TrilioVault license.

        The license file must already exist inside the trilio-wlm workload
        container (copy it there first, e.g.
        `kubectl cp <file> openstack/trilio-wlm-k8s-0:/tmp/license -c trilio-wlm`),
        then pass its in-container path as license-file-path.

        Auth uses the WLM service account from the identity-service relation
        (the same credentials the old charm-trilio-wlm's create_license()
        action used) — no password parameter needed.

        'workloadmgr license-create' normally shows the EULA text via curses
        and blocks on a real keypress ('y' to accept) before it ever calls
        the API. The '--accept-eula' flag (added in workloadmgrclient for
        TVAULT-7518) agrees to the EULA up front and skips that curses block
        entirely. 'setsid' is still required — that guards against a
        separate, always-present issue where cmd2 itself opens /dev/tty at
        startup and fails with "cbreak() returned ERR" under Pebble exec.
        """
        if not self.unit.is_leader():
            event.fail("Run this action on the leader unit only")
            return
        identity = self._identity_data()
        if not identity:
            event.fail("identity-service relation not ready — wait for charm to reach active status")
            return
        container = self.unit.get_container(CONTAINER)
        if not container.can_connect():
            event.fail("Workload container not ready")
            return
        license_file_path = event.params["license-file-path"]
        auth_url = (
            f"{identity['service_protocol']}://"
            f"{identity['service_host']}:{identity['service_port']}/v3"
        )
        cmd = [
            "setsid",
            "workloadmgr",
            "--os-username", identity["service_username"],
            "--os-password", identity["service_password"],
            "--os-auth-url", auth_url,
            "--os-user-domain-name", "service_domain",
            "--os-project-domain-name", "service_domain",
            "--os-project-name", identity["service_tenant"],
            "--os-region-name", self.config.get("region", "RegionOne"),
            "license-create", license_file_path, "-f", "json", "--accept-eula",
        ]
        try:
            process = container.exec(cmd)
            out, err = process.wait_output()
            logger.info("license-create output: %s", out)
            event.set_results({"result": "License applied successfully", "output": out})
        except Exception as e:
            event.fail(f"license-create failed: {e}")

    def _send_relation_requests(self):
        """Write requirer data to all relations. Idempotent — safe to call on every configure.

        Handles the case where relation-joined fired before the charm was working.
        """
        if not self.unit.is_leader():
            return
        amqp_rel = self.model.get_relation("amqp")
        if amqp_rel:
            amqp_rel.data[self.app]["username"] = "wlm"
            amqp_rel.data[self.app]["vhost"] = "wlm"
        db_rel = self.model.get_relation("database")
        if db_rel and not db_rel.data[self.app].get("database"):
            db_rel.data[self.app]["database"] = "workloadmgr"
        ks_rel = self.model.get_relation("identity-service")
        if ks_rel and not ks_rel.data[self.app].get("service-endpoints"):
            self._register_keystone_service()

    def _configure(self, event):
        self._send_relation_requests()
        self._patch_fuse_device()
        self._patch_shared_vault_mount()
        container = self.unit.get_container(CONTAINER)
        dms_container = self.unit.get_container(DMS_CONTAINER)
        if not container.can_connect() or not dms_container.can_connect():
            self.unit.status = ops.WaitingStatus("Waiting for Pebble in workload container")
            event.defer()
            return

        missing = self._missing_relations()
        if missing:
            self.unit.status = ops.WaitingStatus(f"Waiting for: {', '.join(missing)}")
            return

        self._write_config(container)
        self._write_dms_client_config(container)
        self._write_ca_cert(container)
        # Run DB migrations before starting services (idempotent — safe on every leader call).
        if self.unit.is_leader():
            self._db_sync(container)
        self._update_pebble_layer(container)

        # Embedded DMS server, co-located 1:1 with this WLM pod (see module docstring).
        self._write_dms_server_config(dms_container)
        self._write_dms_s3vaultfuse_config(dms_container)
        self._write_ca_cert(dms_container)
        self._update_dms_pebble_layer(dms_container)

        # Expose WLM_PORT so Juju creates the k8s Service port entry.
        # Without this, intra-cluster traffic to wlm-api cannot reach the pod.
        self.unit.open_port("tcp", WLM_PORT)

        if self.unit.is_leader():
            self._publish_wlm_service_data()
            self._register_keystone_service()
            identity = self._identity_data()
            if identity:
                self._ensure_service_user_default_project(container, identity)

        self.unit.status = ops.ActiveStatus("WLM ready")

    # --- relation data helpers ---

    def _missing_relations(self):
        missing = []
        if not self._db_data():
            missing.append("database")
        if not self._amqp_data():
            missing.append("amqp")
        if not self._amqp_dms_data():
            missing.append("amqp-dms")
        if not self._identity_data():
            missing.append("identity-service")
        return missing

    def _db_data(self):
        """mysql_client interface: provider writes into its application databag.

        Keys: endpoints (host:port), username, password, database.
        """
        rel = self.model.get_relation("database")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        if d.get("endpoints") and d.get("password"):
            return d
        return None

    def _amqp_data(self):
        """rabbitmq-k8s: provider writes hostname and password into its application databag."""
        rel = self.model.get_relation("amqp")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        host = d.get("hostname") or d.get("host")
        if host and d.get("password"):
            return {**dict(d), "host": host}
        return None

    def _amqp_dms_data(self):
        """rabbitmq-k8s: dmapi-vhost credentials for the DMS RPC channel (see amqp-dms relation)."""
        rel = self.model.get_relation("amqp-dms")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        host = d.get("hostname") or d.get("host")
        if host and d.get("password"):
            return {**dict(d), "host": host}
        return None

    def _identity_data(self):
        """keystone-k8s: provider writes credentials via Juju secret in its app databag.

        Returns a normalized dict with underscore-keyed fields matching _write_config usage.
        """
        rel = self.model.get_relation("identity-service")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        secret_id = d.get("service-credentials")
        if not secret_id or not d.get("service-host"):
            return None
        try:
            secret = self.model.get_secret(id=secret_id)
            creds = secret.get_content()
        except Exception:
            return None
        return {
            "service_host": d.get("service-host"),
            "service_port": d.get("service-port", "5000"),
            "service_protocol": d.get("service-protocol", "http"),
            "service_username": creds.get("username"),
            "service_password": creds.get("password"),
            "service_tenant": d.get("service-project-name", "services"),
            "service_domain_name": d.get("service-domain-name", "Default"),
            "service_domain_id": d.get("service-domain-id", "default"),
            # keystone-k8s also publishes the human "admin" identity's own
            # IDs on this same relation (matching the older charm-trilio-wlm
            # reactive charm's identity_service.get('admin_user_id') /
            # 'admin_project_id') — used as the default source for
            # cloud_admin_user_id/cloud_admin_project_id in _write_config,
            # since workloadmgr's own cloud-admin trust lookup needs the
            # *human* admin's Keystone UUIDs, not WLM's own service account.
            "admin_user_id": d.get("admin-user-id", ""),
            "admin_project_id": d.get("admin-project-id", ""),
            "admin_domain_id": d.get("admin-domain-id", ""),
        }

    def _patch_fuse_device(self):
        """Grant the trilio-dms container /dev/fuse + SYS_ADMIN so s3vaultfuse can mount.

        s3vaultfuse runs in the embedded DMS container (trilio-dms), not the
        WLM container itself — trilio-wlm never mounts anything directly.
        Sidecar k8s charms (charmcraft.yaml `containers:`) have no field for
        securityContext/host-device access, so this patches the underlying
        StatefulSet directly via the Kubernetes API. Requires `juju trust`
        (already set on this app in trilio-ctlplane-bundle.yaml) — without it
        the API call fails with a 403 and the unit falls back to WaitingStatus.
        Idempotent: skips the patch (and the pod restart it would trigger) once
        the container already has it.
        """
        namespace = self.model.name
        name = self.app.name
        client = Client()
        try:
            sts = client.get(StatefulSet, name=name, namespace=namespace)
        except Exception as e:
            logger.warning("Could not read StatefulSet %s: %s", name, e)
            return

        target = next(
            (c for c in sts.spec.template.spec.containers if c.name == DMS_CONTAINER),
            None,
        )
        if target is None:
            logger.warning("Container %s not found in StatefulSet %s", DMS_CONTAINER, name)
            return

        already_patched = (
            target.securityContext and target.securityContext.privileged
            and any(vm.name == "dev-fuse" for vm in (target.volumeMounts or []))
        )
        if already_patched:
            return

        patch = {
            "spec": {
                "template": {
                    "spec": {
                        "containers": [
                            {
                                "name": DMS_CONTAINER,
                                "securityContext": {"privileged": True},
                                "volumeMounts": [
                                    {"name": "dev-fuse", "mountPath": "/dev/fuse"}
                                ],
                            }
                        ],
                        "volumes": [
                            {
                                "name": "dev-fuse",
                                "hostPath": {"path": "/dev/fuse", "type": "CharDevice"},
                            }
                        ],
                    }
                }
            }
        }
        try:
            client.patch(
                StatefulSet, name=name, namespace=namespace,
                obj=patch, patch_type=PatchType.STRATEGIC,
            )
            logger.info("Patched StatefulSet %s with FUSE device access", name)
        except Exception as e:
            logger.error("Failed to patch StatefulSet %s for FUSE access: %s", name, e)

    def _patch_shared_vault_mount(self):
        """Share VAULT_MOUNTS_PATH between trilio-wlm and the embedded trilio-dms container.

        DMS performs the actual `mount` syscall for NFS/S3 backup targets inside
        its own container. Even within the same pod, one container's mount()
        calls aren't automatically visible in a sibling's mount namespace —
        Kubernetes still requires explicit mountPropagation for that, volume
        type aside. trilio-dms's side uses `Bidirectional` (push its mounts up),
        trilio-wlm's side uses `HostToContainer` (receive them). Because the two
        containers are guaranteed co-located (same pod, not just scheduled that
        way), an ordinary emptyDir volume works here — no hostPath, no
        podAffinity, no node pinning needed at all (unlike the old cross-pod
        design against a separate trilio-dms-k8s app).
        Idempotent: skips the patch (and the pod restart it would trigger) once
        the vault-mounts volume is already emptyDir-typed. Checks the volume's
        actual *type*, not just its name — a charm upgrade from the old
        cross-pod hostPath+podAffinity design left a same-named "vault-mounts"
        volume in place, which a presence-only check would wrongly treat as
        already patched, permanently breaking scheduling (the stale podAffinity
        rule requires co-location with a trilio-dms-k8s app that no longer
        exists once DMS is embedded).
        """
        namespace = self.model.name
        name = self.app.name
        client = Client()
        try:
            sts = client.get(StatefulSet, name=name, namespace=namespace)
        except Exception as e:
            logger.warning("Could not read StatefulSet %s: %s", name, e)
            return

        volumes = sts.spec.template.spec.volumes or []
        vault_volume = next((v for v in volumes if v.name == "vault-mounts"), None)
        already_patched = vault_volume is not None and vault_volume.emptyDir is not None
        if already_patched:
            return

        patch = {
            "spec": {
                "template": {
                    "spec": {
                        # Explicit null clears the old podAffinity rule entirely —
                        # a strategic merge patch only ever merges/adds fields by
                        # default, so a stale affinity block would otherwise survive
                        # even after this charm stops setting one.
                        "affinity": None,
                        "containers": [
                            {
                                "name": CONTAINER,
                                "volumeMounts": [
                                    {
                                        "name": "vault-mounts",
                                        "mountPath": VAULT_MOUNTS_PATH,
                                        "mountPropagation": "HostToContainer",
                                    }
                                ],
                            },
                            {
                                "name": DMS_CONTAINER,
                                "volumeMounts": [
                                    {
                                        "name": "vault-mounts",
                                        "mountPath": VAULT_MOUNTS_PATH,
                                        "mountPropagation": "Bidirectional",
                                    }
                                ],
                            },
                        ],
                        "volumes": [
                            {
                                "name": "vault-mounts",
                                "emptyDir": {},
                                # Explicit null clears the old hostPath source so the
                                # volume ends up purely emptyDir-typed, not both at once.
                                "hostPath": None,
                            }
                        ],
                    }
                }
            }
        }
        try:
            client.patch(
                StatefulSet, name=name, namespace=namespace,
                obj=patch, patch_type=PatchType.STRATEGIC,
            )
            logger.info("Patched StatefulSet %s with shared in-pod vault mount", name)
        except Exception as e:
            logger.error("Failed to patch StatefulSet %s for shared vault mount: %s", name, e)

    def _get_ca_cert(self):
        """Return concatenated CA certs from receive-ca-cert relation, or None."""
        rel = self.model.get_relation("receive-ca-cert")
        if not rel:
            return None
        certs = [
            rel.data[unit]["ca"].strip()
            for unit in rel.units
            if rel.data[unit].get("ca")
        ]
        return "\n".join(certs) if certs else None

    def _get_ca_bundle_env(self):
        """Return env dict with REQUESTS_CA_BUNDLE when a CA cert is configured."""
        if self._get_ca_cert():
            return {"REQUESTS_CA_BUNDLE": "/usr/local/share/ca-certificates/ca-bundle.crt"}
        return {}

    def _write_ca_cert(self, container):
        """Write CA bundle into the container and refresh the system trust store."""
        ca_cert = self._get_ca_cert()
        if not ca_cert:
            return
        # update-ca-certificates only processes *.crt files — must use .crt extension
        container.push(
            "/usr/local/share/ca-certificates/ca-bundle.crt",
            ca_cert,
            make_dirs=True,
        )
        container.exec(["update-ca-certificates"]).wait()
        logger.info("CA bundle written to container")

    def _db_sync(self, container):
        """Run WLM database migrations via alembic (idempotent; leader only).

        WLM uses alembic (not wlm-manage db_sync). The [alembic] section written
        into triliovault-wlm.conf provides sqlalchemy.url and script_location so
        alembic can find the migration repo without a separate alembic.ini.
        """
        container.exec(
            ["alembic", "--config", CONFIG_PATH, "upgrade", "head"],
        ).wait()
        logger.info("alembic WLM upgrade head completed")

    # --- config file rendering ---

    def _render_template(self, template_name: str, context: dict) -> str:
        """Render a Jinja2 template from src/templates/."""
        loader = jinja2.FileSystemLoader(TEMPLATE_DIR)
        env = jinja2.Environment(loader=loader, keep_trailing_newline=True)
        return env.get_template(template_name).render(**context)

    def _write_config(self, container):
        db = self._db_data()
        amqp = self._amqp_data()
        identity = self._identity_data()

        # mysql_client: endpoints is "host:port" (may be comma-separated for HA)
        endpoint = db["endpoints"].split(",")[0].strip()
        db_host, _, db_port = endpoint.partition(":")
        db_port = db_port or "3306"
        db_url = (
            f"mysql+pymysql://{db['username']}:{db['password']}"
            f"@{db_host}:{db_port}/{db['database']}"
        )
        transport_url = (
            f"rabbit://{amqp.get('username', 'workloadmgr')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'workloadmgr')}"
        )
        auth_url = (
            f"{identity.get('service_protocol', 'http')}://"
            f"{identity['service_host']}:{identity.get('service_port', '5000')}/v3"
        )
        # Provide cafile path only when the CA cert has been pushed to the container.
        cafile = CA_BUNDLE_PATH if self._get_ca_cert() else ""

        context = {
            "wlm_logging_conf_path": WLM_LOGGING_CONF_PATH,
            "my_ip": "0.0.0.0",
            "state_path": "/var/lib/workloadmgr",
            "sql_connection": db_url,
            "osapi_workloads_listen_port": WLM_PORT,
            # Explicit charm config always wins; otherwise default to the human
            # "admin" identity's own IDs, which keystone-k8s already publishes
            # on the identity-service relation (see _identity_data) — matching
            # how the older charm-trilio-wlm reactive charm sourced these same
            # two fields from identity_service.get('admin_user_id')/
            # 'admin_project_id'. Without this, workloadmgr's own cloud-admin
            # trust lookup (workloadmgr/compute/nova.py's
            # _get_trusts('cloud_admin', CONF.cloud_admin_project_id)) can
            # never match a real trust record, since that option otherwise
            # defaults to the literal string "admin" in workloadmgr's own code.
            "cloud_admin_user_id": (
                self.config.get("cloud-admin-user-id") or identity.get("admin_user_id", "")
            ),
            "cloud_admin_project_id": (
                self.config.get("cloud-admin-project-id") or identity.get("admin_project_id", "")
            ),
            "cloud_admin_domain": self.config.get("cloud-admin-domain", "admin_domain"),
            "cloud_admin_role": self.config.get("cloud-admin-role", "admin"),
            "trustee_role": self.config.get("trustee-role", "member, creator, admin"),
            "rabbit_quorum_queue": str(self.config.get("rabbit-quorum-queue", True)).lower(),
            "amqp_durable_queues": str(self.config.get("amqp-durable-queues", True)).lower(),
            "cloud_unique_id": self.config.get("cloud-unique-id", ""),
            "region_name_for_services": self.config["region"],
            "transport_url": transport_url,
            "api_workers": self.config["api-workers"],
            "workloads_workers": self.config["workloads-workers"],
            "glance_production_api_servers": self.config["glance-endpoint"],
            "auth_url": auth_url,
            "cinder_production_endpoint_template": self.config["cinder-endpoint"],
            "nova_production_endpoint_template": self.config["nova-endpoint"],
            "neutron_production_url": self.config["neutron-endpoint"],
            "rabbit_virtual_host": amqp.get("vhost", "wlm"),
            "log_dir": LOG_DIR,
            "debug": str(self.config["debug"]).lower(),
            "keystone_project_name": identity.get("service_tenant", "services"),
            "keystone_username": identity.get("service_username", "wlm"),
            "keystone_password": identity["service_password"],
            "service_domain_name": identity.get("service_domain_name", "Default"),
            "service_domain_id": identity.get("service_domain_id", "default"),
            "cafile": cafile,
        }
        rendered = self._render_template("triliovault-wlm.conf.j2", context)
        container.push(CONFIG_PATH, rendered, make_dirs=True)
        logger.info("Wrote %s", CONFIG_PATH)
        container.push(
            WLM_LOGGING_CONF_PATH,
            self._render_template("wlm_logging.conf.j2", {}),
            make_dirs=True,
        )
        logger.info("Wrote %s", WLM_LOGGING_CONF_PATH)
        traefik_prefix = f"/{WLM_INGRESS_MODEL}-{WLM_INGRESS_NAME}"
        container.push(
            API_PASTE_PATH,
            self._render_template("api-paste.ini.j2", {"traefik_prefix": traefik_prefix}),
            make_dirs=True,
        )
        logger.info("Wrote %s", API_PASTE_PATH)

    def _dms_node_id(self):
        """Identifier for this unit's own embedded DMS server (see module docstring).

        Each WLM pod embeds its own DMS server 1:1 — this just needs to be
        deterministic and unique per unit, not tied to a nova-compute host
        identity (that's the *data-plane* DMS instance's job, on
        trilio-data-mover-sunbeam, unrelated to this one). WLM's own DMS
        client config (below) uses this same value to talk to its own
        co-located server, never anyone else's.
        """
        return self.unit.name.replace("/", "-")

    def _write_dms_client_config(self, container):
        """Write DMS client config for the trilio-dms client library inside WLM.

        Db url is WLM's own database (not DMAPI's). RabbitMQ uses the
        *workloadmgr* vhost (amqp-dms relation) — same as WLM's own transport,
        matching RHOSO18 pattern where WLM-side DMS uses the workloadmgr vhost.
        node_id targets this unit's own embedded DMS server (see _dms_node_id).
        Written once — all four WLM services share the same container filesystem.
        """
        amqp_dms = self._amqp_dms_data()
        db = self._db_data()

        endpoint = db["endpoints"].split(",")[0].strip()
        db_host, _, db_port = endpoint.partition(":")
        db_port = db_port or "3306"
        db_url = (
            f"mysql+pymysql://{db['username']}:{db['password']}"
            f"@{db_host}:{db_port}/{db['database']}"
        )
        rabbitmq_url = (
            f"rabbit://{amqp_dms.get('username', 'workloadmgr')}:{amqp_dms['password']}"
            f"@{amqp_dms['host']}:{amqp_dms.get('port', '5672')}"
            f"/{amqp_dms.get('vhost', 'workloadmgr')}"
        )
        context = {
            "rabbitmq_url": rabbitmq_url,
            "db_url": db_url,
            "node_id": self._dms_node_id(),
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "log_file": "/var/log/triliovault/trilio-dms-client.log",
        }
        rendered = self._render_template("triliovault-dms-client.conf.j2", context)
        container.push(DMS_CLIENT_CONF, rendered, make_dirs=True)
        logger.info("Wrote %s", DMS_CLIENT_CONF)

    def _write_dms_server_config(self, container):
        """Write server.conf for the embedded DMS server in the trilio-dms container.

        Reuses WLM's own already-computed Keystone auth_url and CA cert
        (this unit's own identity-service/receive-ca-cert relation data)
        rather than a separate config option — the embedded server only ever
        serves this one co-located WLM unit, so there's nothing to configure
        independently.
        """
        amqp_dms = self._amqp_dms_data()
        identity = self._identity_data()
        rabbitmq_url = (
            f"rabbit://{amqp_dms.get('username', 'workloadmgr')}:{amqp_dms['password']}"
            f"@{amqp_dms['host']}:{amqp_dms.get('port', '5672')}"
            f"/{amqp_dms.get('vhost', 'workloadmgr')}"
        )
        auth_url = (
            f"{identity.get('service_protocol', 'http')}://"
            f"{identity['service_host']}:{identity.get('service_port', '5000')}/v3"
        )
        has_ca = bool(self._get_ca_cert())
        context = {
            "rabbitmq_url": rabbitmq_url,
            "node_id": self._dms_node_id(),
            "auth_url": auth_url,
            "barbican_ssl_verify": "True" if has_ca else "False",
            "cafile": CA_BUNDLE_PATH if has_ca else "",
            "log_file": DMS_SERVER_LOG_FILE,
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "worker_threads": self.config["dms-worker-threads"],
            "rabbitmq_queue_type": (
                "quorum" if self.config.get("rabbit-quorum-queue", True) else "classic"
            ),
            "rabbitmq_queue_durable": str(self.config.get("amqp-durable-queues", True)).lower(),
        }
        rendered = self._render_template("triliovault-dms-server.conf.j2", context)
        container.push(DMS_SERVER_CONF, rendered, make_dirs=True)
        logger.info("Wrote %s", DMS_SERVER_CONF)

    def _write_dms_s3vaultfuse_config(self, container):
        container.push(
            S3VAULTFUSE_CONF,
            self._render_template("s3vaultfuse-global.conf.j2", {}),
            make_dirs=True,
        )
        logger.info("Wrote %s", S3VAULTFUSE_CONF)
        container.push(
            OBJECT_STORE_LOGGING_CONF_PATH,
            self._render_template("object_store_logging.conf.j2", {}),
            make_dirs=True,
        )
        logger.info("Wrote %s", OBJECT_STORE_LOGGING_CONF_PATH)

    def _update_dms_pebble_layer(self, container):
        layer = ops.pebble.Layer({
            "summary": "TrilioVault DMS server (embedded)",
            "services": {
                "trilio-dms-server": {
                    "override": "replace",
                    "summary": "DMS server",
                    "command": (
                        f"/usr/bin/python3 /usr/bin/trilio-dms-server"
                        f" --config-file {DMS_SERVER_CONF}"
                    ),
                    "startup": "enabled",
                    "environment": self._get_ca_bundle_env(),
                }
            },
        })
        container.add_layer(DMS_CONTAINER, layer, combine=True)
        container.replan()
        logger.info("Pebble layer applied for embedded trilio-dms-server")

    # --- Pebble layer ---

    def _build_pebble_layer(self):
        # Binaries are named workloadmgr-* (confirmed from the installed package).
        # The Pebble service names (keys) are kept as wlm-* for readability.
        #
        # TVAULT-7404 root-user experiment: Juju's k8s sidecar charm packaging
        # runs Pebble (and, by default, every service it launches) as root,
        # overriding the image's own "USER nova" directive. We previously
        # pinned "user"/"group": "nova" on each service below to match
        # contego's own identity on the compute side (see
        # nova-user-known-good-state.md for that approach and how to roll
        # back to it) — trying root here instead to see if that resolves the
        # NFS/permission issues more simply than matching UIDs everywhere.
        cmd_base = f"/usr/bin/{{}} --config-file {CONFIG_PATH}"
        env = self._get_ca_bundle_env()
        services = {
            "wlm-api": {
                "override": "replace",
                "summary": "WLM API",
                "command": cmd_base.format("workloadmgr-api"),
                "startup": "enabled",
                "environment": env,
            },
            "wlm-workloads": {
                "override": "replace",
                "summary": "WLM Workloads",
                "command": cmd_base.format("workloadmgr-workloads"),
                "startup": "enabled",
                "environment": env,
            },
            "wlm-scheduler": {
                "override": "replace",
                "summary": "WLM Scheduler",
                "command": cmd_base.format("workloadmgr-scheduler"),
                "startup": "enabled",
                "environment": env,
            },
        }
        # wlm-cron must run as a single instance cluster-wide.
        # Multiple wlm-cron instances cause duplicate scheduled job execution
        # and corrupt workload state in the database.
        # Always include the service definition so Pebble can disable it on non-leaders;
        # omitting it entirely leaves a previously-enabled layer in force.
        services["wlm-cron"] = {
            "override": "replace",
            "summary": "WLM Cron (leader-only singleton)",
            "command": cmd_base.format("workloadmgr-cron"),
            "startup": "enabled" if self.unit.is_leader() else "disabled",
            "environment": env,
        }
        return ops.pebble.Layer({"summary": "TrilioVault WLM services", "services": services})

    def _update_pebble_layer(self, container):
        layer = self._build_pebble_layer()
        container.add_layer(CONTAINER, layer, combine=True)
        container.replan()
        logger.info("Pebble layer applied; services: %s", list(layer.services))

    # --- cross-model relation data ---

    def _publish_wlm_service_data(self):
        rel = self.model.get_relation("wlm-service")
        if not rel:
            return
        db = self._db_data()
        wlm_db_url = ""
        if db:
            endpoint = db["endpoints"].split(",")[0].strip()
            db_host, _, db_port = endpoint.partition(":")
            db_port = db_port or "3306"
            wlm_db_url = (
                f"mysql+pymysql://{db['username']}:{db['password']}"
                f"@{db_host}:{db_port}/{db['database']}"
            )
        rel.data[self.app]["wlm-api-url"] = f"http://{self.app.name}:{WLM_PORT}"
        rel.data[self.app]["wlm-db-url"] = wlm_db_url

    def _get_ingress_url(self, rel_name):
        """Return the URL published by Traefik for the given ingress relation, or None."""
        rel = self.model.get_relation(rel_name)
        if not rel:
            return None
        try:
            raw = rel.data[rel.app].get("ingress")
            if raw:
                return json.loads(raw)["url"]
        except (KeyError, json.JSONDecodeError):
            pass
        return None

    def _register_keystone_service(self):
        """Write WLM endpoint registration data into the identity-service relation.

        Uses Traefik-provided https:// URLs when available so Keystone catalog
        entries match the actual reachable endpoints (TLS-terminated by Traefik).
        Falls back to plain-http k8s service URL when ingress is not yet configured.
        """
        rel = self.model.get_relation("identity-service")
        if not rel or not self.unit.is_leader():
            return
        fallback = f"http://{self.app.name}:{WLM_PORT}"
        public_base = (
            self._get_ingress_url("ingress-public")
            or self._get_ingress_url("ingress-internal")
            or fallback
        )
        internal_base = self._get_ingress_url("ingress-internal") or fallback
        endpoints = [{
            "admin_url": WLM_ENDPOINT_TEMPLATE.format(fallback),
            "description": "TrilioVault Backup and Recovery Service",
            "internal_url": WLM_ENDPOINT_TEMPLATE.format(internal_base),
            "public_url": WLM_ENDPOINT_TEMPLATE.format(public_base),
            "service_name": WLM_SERVICE_NAME,
            "type": WLM_SERVICE_TYPE,
        }]
        rel.data[self.app].update({
            "service-endpoints": json.dumps(endpoints),
            "region": self.config.get("region", "RegionOne"),
        })

    def _ensure_service_user_default_project(self, container, identity):
        """Set this service account's own Keystone default_project_id.

        workloadmgr's own client-session code (workloadmgr/compute/nova.py,
        novaclient/nova_micro_client) never passes an explicit project scope
        when authenticating — it relies entirely on Keystone auto-scoping to
        the authenticating user's own default_project_id when none is given.
        keystone-k8s's identity-service interface has no field for requesting
        this at account-creation time, so it's left null, producing an
        UNSCOPED (empty service catalog) token on every workloadmgr
        nova/cinder/glance call and breaking all workload/snapshot creation
        with "The service catalog is empty." — confirmed by direct comparison
        against a working charm-trilio-wlm (reactive charm) deployment, whose
        equivalent service account DOES have default_project_id set (to its
        own "services" project). Idempotent — skips the update API call once
        already set correctly.
        """
        script = (
            "import json, sys\n"
            "from keystoneauth1.identity import v3\n"
            "from keystoneauth1 import session\n"
            "from keystoneclient.v3 import client as keystone_client\n"
            "auth = v3.Password(auth_url=sys.argv[1], username=sys.argv[2],\n"
            "    password=sys.argv[3], user_domain_name=sys.argv[4],\n"
            "    project_name=sys.argv[5], project_domain_name=sys.argv[4])\n"
            "sess = session.Session(auth=auth)\n"
            "kc = keystone_client.Client(session=sess)\n"
            "user_id = sess.get_user_id()\n"
            "project_id = sess.get_project_id()\n"
            "user = kc.users.get(user_id)\n"
            "if getattr(user, 'default_project_id', None) == project_id:\n"
            "    print(json.dumps({'changed': False, 'project_id': project_id}))\n"
            "else:\n"
            "    kc.users.update(user, default_project=project_id)\n"
            "    print(json.dumps({'changed': True, 'project_id': project_id}))\n"
        )
        auth_url = (
            f"{identity['service_protocol']}://"
            f"{identity['service_host']}:{identity['service_port']}/v3"
        )
        try:
            process = container.exec(
                ["python3", "-c", script, auth_url, identity["service_username"],
                 identity["service_password"], identity["service_domain_name"],
                 identity["service_tenant"]],
            )
            out, _ = process.wait_output()
            logger.info("Service account default-project check: %s", out.strip())
        except Exception as e:
            logger.warning("Could not set service account default_project_id: %s", e)

    def _publish_ingress(self, rel):
        """Write traefik_k8s ingress requirer data.

        Matches IngressPerAppRequirer from charms.traefik_k8s.v2.ingress:
        - Leader writes app databag: model, name, port (individual JSON-encoded keys).
        - Every unit writes its own unit databag: host, ip (required by Traefik's
          is_ready validation before it will publish the ingress URL back).
        """
        # App databag — leader only.
        if self.unit.is_leader():
            if "data" in rel.data[self.app]:
                del rel.data[self.app]["data"]
            rel.data[self.app]["model"] = json.dumps(WLM_INGRESS_MODEL)
            rel.data[self.app]["name"] = json.dumps(WLM_INGRESS_NAME)
            rel.data[self.app]["port"] = json.dumps(WLM_PORT)
        # Unit databag — every unit. Traefik validates host/ip for each unit
        # before it considers the requirer ready and publishes the ingress URL.
        binding = self.model.get_binding(rel)
        ip = (
            str(binding.network.bind_address)
            if binding and binding.network.bind_address
            else None
        )
        rel.data[self.unit]["host"] = json.dumps(socket.getfqdn())
        if ip:
            rel.data[self.unit]["ip"] = json.dumps(ip)


if __name__ == "__main__":
    ops.main(TrilioWlmK8sCharm)
