#!/usr/bin/env python3
# Ensure charm venv is on sys.path regardless of how the dispatch script is generated.
import sys as _sys, pathlib as _pathlib
_venv = _pathlib.Path(__file__).parent.parent / "venv"
if str(_venv) not in _sys.path:
    _sys.path.insert(0, str(_venv))
del _sys, _pathlib

"""TrilioVault DataMover subordinate charm for Sunbeam Canonical OpenStack.

Installs tvault-contego AND the compute-side trilio-dms-server on every
openstack-hypervisor compute node.

Automatically co-located via juju-info subordinate relation — no manual
action needed when a new compute node joins the cluster via sunbeam cluster join.

DMS note: A DMS server must run on both the control plane (embedded as the
trilio-dms sidecar container inside trilio-wlm-k8s's own pod) and every
compute node (this charm). The instances communicate via RabbitMQ and handle
NFS / S3 mount operations on their respective hosts.
"""

import configparser
import grp as _grp
import hashlib
import json
import jinja2
import pwd
import re
import logging
import os
import pathlib
import shutil
import socket
import subprocess
import xml.etree.ElementTree as ET

import ops

logger = logging.getLogger(__name__)

DATAMOVER_PACKAGE = "python3-tvault-contego"
DATAMOVER_SERVICE = "triliovault-datamover"
DMS_SERVICE = "triliovault-dms"
DM_CONFIG_PATH = "/etc/triliovault-datamover/triliovault-datamover.conf"
DM_LOGGING_CONF_PATH = "/etc/triliovault-datamover/datamover_logging.conf"
# nova.conf lives inside the openstack-hypervisor snap (root:root 640, unreadable by
# the nova user that tvault-contego runs as).  The charm copies it to NOVA_CONF_COPY
# (root:nova 640) and rewrites the cafile= line to point to CA_BUNDLE_COPY instead
# of the snap-internal path, which is also root-only.  The CA cert itself is obtained
# from the receive-ca-cert Juju relation (not copied from the snap) and written to
# CA_BUNDLE_COPY with root:nova 640 so the nova user can read it.
SNAP_NOVA_CONF = "/var/snap/openstack-hypervisor/common/etc/nova/nova.conf"
NOVA_CONF_COPY = "/etc/triliovault-datamover/nova.conf"
CA_BUNDLE_COPY = "/etc/triliovault-datamover/ca-bundle.pem"
DMS_CONFIG_PATH = "/etc/triliovault-dms/server.conf"
DMS_CLIENT_CONF_PATH = "/etc/triliovault-dms/client.conf"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
OBJECT_STORE_LOGGING_CONF_PATH = "/etc/triliovault-object-store/object_store_logging.conf"
DMS_LOG_FILE = "/var/log/triliovault/trilio-dms-server.log"
DMS_CLIENT_LOG_FILE = "/var/log/triliovault/trilio-dms-client.log"
TRILIO_LIST_PATH = "/etc/apt/sources.list.d/trilio.list"
TEMPLATE_DIR = pathlib.Path(__file__).parent / "templates"
NOVA_TARGET_UID = 42436  # Standard OpenStack nova UID (Kolla, UCA, WLM container all use this)
NOVA_INSTANCES_DIR = "/var/snap/openstack-hypervisor/common/lib/nova/instances"
NOVA_INSTANCES_SNAPSHOTS_DIR = f"{NOVA_INSTANCES_DIR}/snapshots"

# contego needs its own Ceph client credentials to run rbd commands directly
# (backend probing, snapshot info) against any Ceph-backed Cinder volume attached
# to an instance — this is separate from, and not needed by, Nova's own attach
# flow (Nova gets a per-attachment secret dynamically from Cinder's
# connection_info and never talks to the Ceph cluster directly for that case).
# Credentials are obtained via a dedicated ceph-client relation to the same
# ceph-mon/microceph application cinder-volume-ceph already uses, requesting a
# key scoped to read/write/execute on whichever pools are actually in use —
# never a brand new pool of our own.
#
# The ceph-mon/microceph broker auto-provisions a client key named after the
# REQUESTING JUJU APPLICATION the moment the relation is established — that
# key already exists with a default (unscoped) osd cap before we ever send our
# own broker request, which only *modifies* caps on an existing key rather
# than creating one. So the client name here must match self.app.name exactly,
# not an arbitrary string — a mismatch means our requests silently target a
# key that was never created (ceph auth caps on a nonexistent client fails,
# but the broker swallows that error and still reports exit-code 0).
CEPH_CONF_PATH = "/etc/ceph/ceph.conf"
# Records the last set of pools our ceph key was scoped to, so we only send a
# follow-up broker request when that set actually changes (new pool discovered,
# or one disappeared) rather than on every hook run.
CEPH_GRANTED_POOLS_MARKER = "/var/lib/trilio-data-mover/.ceph-granted-pools"

# Systemd unit for the DMS server on compute nodes.
# python3-trilio-dms is designed for kolla (container); it ships no systemd unit.
DMS_SYSTEMD_UNIT = """\
[Unit]
Description=TrilioVault Dynamic Mount Service
After=network.target

[Service]
# TVAULT-7404 root-user experiment (see nova-user-known-good-state.md for
# rollback). Was User=nova/Group=nova.
User=root
Group=root
Type=simple
Environment="PYTHONPATH=/snap/openstack-hypervisor/current/usr/lib/python3/dist-packages"
ExecStart=/usr/bin/python3 /usr/bin/trilio-dms-server --config-file /etc/triliovault-dms/server.conf
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""

# Systemd unit for tvault-contego on Sunbeam compute nodes.
# nova.conf lives inside the openstack-hypervisor snap (root:root 640).
# The charm copies it to NOVA_CONF_COPY (root:nova 640) so tvault-contego can
# read it as the nova user.  PYTHONPATH is required because snap Python packages
# (nova, kombu, etc.) are isolated from the host system path.
DATAMOVER_SYSTEMD_UNIT = """\
[Unit]
Description=TrilioVault DataMover (tvault-contego)
After=network.target
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
# TVAULT-7404 root-user experiment (see nova-user-known-good-state.md for
# rollback). Was User=nova/Group=nova.
User=root
Group=root
Type=simple
Environment="PYTHONPATH=/snap/openstack-hypervisor/current/usr/lib/python3/dist-packages"
ExecStart=/usr/bin/python3 /usr/bin/tvault-contego \
  --config-file=/etc/triliovault-datamover/nova.conf \
  --config-file=/etc/triliovault-datamover/triliovault-datamover.conf
TimeoutStopSec=20
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""



class TrilioDataMoverSunbeamCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.install, self._on_install)
        self.framework.observe(self.on.config_changed, self._on_config_changed)
        self.framework.observe(self.on.upgrade_charm, self._on_upgrade_charm)
        self.framework.observe(self.on.amqp_relation_changed, self._on_relation_changed)
        self.framework.observe(
            self.on.identity_credentials_relation_changed, self._on_relation_changed
        )
        self.framework.observe(self.on.juju_info_relation_joined, self._on_juju_info_joined)
        self.framework.observe(self.on.amqp_relation_joined, self._on_amqp_relation_joined)
        self.framework.observe(
            self.on.identity_credentials_relation_joined,
            self._on_identity_credentials_relation_joined,
        )
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._on_relation_changed
        )
        self.framework.observe(self.on.update_status, self._on_update_status)
        self._setup_ceph_client()

    @property
    def _ceph_client_name(self):
        """Must match self.app.name — see comment above CEPH_CONF_PATH."""
        return self.app.name

    def _ceph_keyring_path(self):
        return f"/etc/ceph/ceph.client.{self._ceph_client_name}.keyring"

    def _setup_ceph_client(self):
        """Wire up the ceph-client relation used to fetch Ceph credentials.

        Lazy-imported so charms/tests that never relate "ceph" don't need the
        dependency importable, and so a missing/optional relation at deploy
        time doesn't break charm startup.
        """
        import interface_ceph_client.ceph_client as ceph_client

        self.ceph = ceph_client.CephClientRequires(self, "ceph")
        self.framework.observe(
            self.ceph.on.broker_available, self._on_ceph_broker_available
        )
        self.framework.observe(
            self.ceph.on.pools_available, self._on_ceph_pools_available
        )

    # --- event handlers ---

    def _on_install(self, event):
        self.unit.status = ops.MaintenanceStatus("Installing TrilioVault packages")
        try:
            self._setup_apt_repo()
            self._install_packages()
            self._create_directories()
            self._write_nova_sudoers()
            self._install_rootwrap_filters()
            self._write_systemd_services()
        except RuntimeError as e:
            # Nova UID conflict — operator must set change-nova-user-id=true or fix manually
            logger.error("Nova user UID conflict: %s", e)
            self.unit.status = ops.BlockedStatus(str(e))
            return
        except subprocess.CalledProcessError as e:
            logger.error("Package install failed: %s", e)
            self.unit.status = ops.BlockedStatus(f"Package install failed: {e}")
            return
        self.unit.status = ops.WaitingStatus("Waiting for amqp and identity-credentials relations")

    def _on_config_changed(self, event):
        self._configure(event)

    def _on_upgrade_charm(self, event):
        self.unit.status = ops.MaintenanceStatus("Upgrading TrilioVault packages")
        try:
            # Re-run apt repo setup on upgrade — the repo URL may have changed between
            # Trilio releases and must be refreshed before installing the new package.
            self._setup_apt_repo()
            self._install_packages()
            # Re-write systemd units on upgrade: the unit files may not have been
            # written by the original install if this was a pre-v14 deployment, or
            # the unit content may have changed between Trilio releases.
            self._create_directories()
            self._write_nova_sudoers()
            self._install_rootwrap_filters()
            self._write_systemd_services()
        except RuntimeError as e:
            logger.error("Nova user UID conflict: %s", e)
            self.unit.status = ops.BlockedStatus(str(e))
            return
        except subprocess.CalledProcessError as e:
            self.unit.status = ops.BlockedStatus(f"Upgrade failed: {e}")
            return
        # Re-send relation requests in case the relations were joined before this charm
        # version had the correct app-bag write logic. Idempotent.
        self._send_relation_requests()
        self._configure(event)

    def _on_relation_changed(self, event):
        self._configure(event)

    def _on_juju_info_joined(self, event):
        self._configure(event)

    def _on_amqp_relation_joined(self, event):
        """Write rabbitmq requirer credentials so rabbitmq-k8s provisions the user/vhost.

        external_connectivity=true tells rabbitmq-k8s to return the loadbalancer IP
        (e.g. 172.26.x.x) instead of the k8s-internal DNS name, which is not
        resolvable from compute nodes outside the k8s cluster.
        """
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "datamover"
            # Must match dm-api's own vhost ("dmapi", not "datamover") — contego's
            # vast_prepare/vast_instance RPC replies are published by dmapi onto
            # the "dmapi" vhost; a mismatched vhost here means contego listens on
            # a queue dmapi never publishes to, and every RPC call silently times
            # out after 30s with no error on either side.
            event.relation.data[self.app]["vhost"] = "dmapi"
            event.relation.data[self.app]["external_connectivity"] = json.dumps(True)

    def _on_identity_credentials_relation_joined(self, event):
        """Write keystone requirer username so keystone-k8s provisions datamover credentials."""
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "datamover"

    def _send_relation_requests(self):
        """Idempotently write requirer bags for amqp and identity-credentials.

        Called on upgrade-charm to handle the case where these relations were
        already joined before the charm had this write logic in place.
        """
        if not self.unit.is_leader():
            return
        amqp_rel = self.model.get_relation("amqp")
        if amqp_rel:
            amqp_rel.data[self.app]["username"] = "datamover"
            # Must match dm-api's own vhost ("dmapi") — see _on_amqp_relation_joined.
            amqp_rel.data[self.app]["vhost"] = "dmapi"
            amqp_rel.data[self.app]["external_connectivity"] = json.dumps(True)
        identity_rel = self.model.get_relation("identity-credentials")
        if identity_rel:
            identity_rel.data[self.app]["username"] = "datamover"

    # --- core configure logic ---

    def _configure(self, event):
        # Nova UID check runs on every configure path (install, relation-changed,
        # config-changed) so no event can override a BlockedStatus set by install.
        # _ensure_nova_user() is a fast no-op when nova is already at 42436.
        try:
            self._ensure_nova_user()
        except RuntimeError as e:
            logger.error("Nova user UID conflict: %s", e)
            self.unit.status = ops.BlockedStatus(str(e))
            return
        except subprocess.CalledProcessError as e:
            self.unit.status = ops.BlockedStatus(f"Nova user setup failed: {e}")
            return

        missing = self._missing_relations()
        if missing:
            self.unit.status = ops.WaitingStatus(f"Waiting for: {', '.join(missing)}")
            return

        try:
            self._write_ca_cert()
            self._sync_nova_conf()
            self._write_datamover_config()
            self._write_dms_config()
            self._write_dms_client_config()
            self._write_s3vaultfuse_config()
            self._restart_services()
        except Exception as e:
            logger.error("Configuration failed: %s", e)
            self.unit.status = ops.BlockedStatus(f"Configuration error: {e}")
            return

        self.unit.status = ops.ActiveStatus("DataMover and DMS running")

    def _missing_relations(self):
        missing = []
        if not self._amqp_data():
            missing.append("amqp")
        if not self._identity_data():
            missing.append("identity-credentials")
        return missing

    # --- relation data helpers ---

    def _amqp_data(self):
        """rabbitmq interface: provider app databag. Accept hostname or host."""
        rel = self.model.get_relation("amqp")
        if not rel:
            return None
        d = rel.data[rel.app]
        host = d.get("hostname") or d.get("host")
        if host and d.get("password"):
            return {**dict(d), "host": host}
        return None

    def _identity_data(self):
        """keystone-credentials interface: provider app databag.

        The keystone-credentials interface returns auth-host, auth-port,
        auth-protocol, and a Juju secret under 'credentials' that holds
        the actual username/password. Returns a normalized dict with
        credentials_host, credentials_password, etc. so callers don't
        need to know the wire format.
        """
        rel = self.model.get_relation("identity-credentials")
        if not rel:
            return None
        d = rel.data[rel.app]
        host = d.get("auth-host")
        secret_id = d.get("credentials")
        if not host or not secret_id:
            return None
        try:
            secret = self.model.get_secret(id=secret_id)
            creds = secret.get_content()
        except Exception:
            return None
        if not creds.get("password"):
            return None
        return {
            "credentials_host": host,
            "credentials_port": d.get("auth-port", "5000"),
            "credentials_protocol": d.get("auth-protocol", "http"),
            "credentials_username": creds.get("username", "datamover"),
            "credentials_password": creds["password"],
            "credentials_project": d.get("project-name", "services"),
            "internal_endpoint": d.get("internal-endpoint", ""),
        }

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

    def _write_ca_cert(self):
        """Write CA bundle from the receive-ca-cert relation to host trust store and to
        a nova-readable path so tvault-contego can verify Keystone TLS.

        CA content comes from the Juju relation — not copied from any snap path.
        CA_BUNDLE_COPY (root:nova 640) is written first so _sync_nova_conf() can
        reference it in the cafile= patch.
        """
        ca_cert = self._get_ca_cert()
        if not ca_cert:
            return
        # Write to our managed path (root:nova 640) for direct use by tvault-contego
        os.makedirs(os.path.dirname(CA_BUNDLE_COPY), exist_ok=True)
        with open(CA_BUNDLE_COPY, "w") as f:
            f.write(ca_cert)
        shutil.chown(CA_BUNDLE_COPY, user="root", group="nova")
        os.chmod(CA_BUNDLE_COPY, 0o640)
        logger.info("CA cert written to %s (root:nova 640)", CA_BUNDLE_COPY)
        # Also add to system trust store so other tools on this host trust the CA
        ca_path = "/usr/local/share/ca-certificates/trilio-ca.crt"
        os.makedirs(os.path.dirname(ca_path), exist_ok=True)
        with open(ca_path, "w") as f:
            f.write(ca_cert)
        subprocess.run(["update-ca-certificates"], check=True)
        logger.info("CA cert added to system trust store via %s", ca_path)

    # --- apt repo and package installation ---

    def _setup_apt_repo(self):
        pkg_source = self.config["triliovault-pkg-source"]
        with open(TRILIO_LIST_PATH, "w") as f:
            f.write(f"{pkg_source}\n")
        subprocess.run(["apt-get", "update", "-qq"], check=True)
        logger.info("Trilio apt repo configured")

    def _ensure_nova_user(self):
        """Create or normalize nova user to UID 42436.

        Sunbeam compute nodes run nova-compute inside the openstack-hypervisor snap,
        so no host-level nova user exists. If a legacy nova user exists (e.g. from
        a nova-common deb install) with a different UID, the charm blocks by default
        to avoid unintended system changes.  Set change-nova-user-id=true to allow
        the UID update.  Both WLM containers and DataMover must use the same nova UID
        (42436) to read/write the same NFS backup target.

        Three cases:
          1. nova user does not exist  → create fresh at UID 42436
          2. nova user exists at 42436 → nothing to do
          3. nova user exists at other UID:
               change-nova-user-id=false → raise RuntimeError (blocks install)
               change-nova-user-id=true  → update UID/GID, re-own nova-owned files
        """
        try:
            pw = pwd.getpwnam("nova")
            current_uid = pw.pw_uid
        except KeyError:
            current_uid = None

        if current_uid is None:
            # Case 1: nova does not exist — create fresh at the correct UID
            try:
                _grp.getgrnam("nova")
            except KeyError:
                subprocess.run(
                    ["groupadd", "--system", "--gid", str(NOVA_TARGET_UID), "nova"],
                    check=False,  # ignore if GID is taken; fallback to system-assigned GID
                )
            subprocess.run(
                ["useradd", "--system", "--no-create-home",
                 "--uid", str(NOVA_TARGET_UID), "--gid", "nova",
                 "--shell", "/usr/sbin/nologin", "nova"],
                check=True,
            )
            logger.info("Created nova user at UID %d", NOVA_TARGET_UID)

        elif current_uid == NOVA_TARGET_UID:
            # Case 2: already correct
            logger.info("nova user already at UID %d — no change needed", NOVA_TARGET_UID)

        else:
            # Case 3: nova exists but has a different UID
            if not self.config.get("change-nova-user-id"):
                raise RuntimeError(
                    f"nova user exists with UID {current_uid} but UID {NOVA_TARGET_UID} is "
                    f"required (WLM containers use {NOVA_TARGET_UID} for NFS access). "
                    f"Set change-nova-user-id=true to allow automatic UID update, "
                    f"or recreate nova at UID {NOVA_TARGET_UID} manually before deploying."
                )
            logger.info(
                "change-nova-user-id=true: updating nova from UID %d to %d",
                current_uid, NOVA_TARGET_UID,
            )
            # Update nova group GID first (usermod -g requires the group to exist at new GID)
            try:
                nova_grp = _grp.getgrnam("nova")
                old_gid = nova_grp.gr_gid
                if old_gid != NOVA_TARGET_UID:
                    subprocess.run(
                        ["groupmod", "--gid", str(NOVA_TARGET_UID), "nova"],
                        check=True,
                    )
            except KeyError:
                subprocess.run(
                    ["groupadd", "--system", "--gid", str(NOVA_TARGET_UID), "nova"],
                    check=True,
                )
                old_gid = None
            # Stop Trilio services before usermod — usermod refuses to change UID
            # while the user has running processes.  stop() + kill(all) ensures
            # all cgroup members (including s3vaultfuse children) are terminated.
            for svc in (DATAMOVER_SERVICE, DMS_SERVICE):
                subprocess.run(["systemctl", "stop", svc], check=False)
                subprocess.run(
                    ["systemctl", "kill", "--kill-who=all", "--signal=SIGKILL", svc],
                    check=False,
                )
            # Update nova user UID
            subprocess.run(
                ["usermod", "--uid", str(NOVA_TARGET_UID),
                 "--gid", str(NOVA_TARGET_UID), "nova"],
                check=True,
            )
            # Re-own files in Trilio directories that were previously owned by old UID/GID.
            # We scope to known Trilio directories rather than running find / (too expensive).
            re_own_dirs = [
                "/etc/triliovault-datamover", "/etc/triliovault-dms",
                "/etc/triliovault-object-store",
                "/var/log/triliovault", "/var/triliovault-mounts",
                "/var/triliovault", "/opt/triliovault",
            ]
            for d in re_own_dirs:
                if os.path.exists(d):
                    subprocess.run(
                        ["find", d, "-user", str(current_uid),
                         "-exec", "chown", "nova:nova", "{}", "+"],
                        check=False,
                    )
                    if old_gid is not None:
                        subprocess.run(
                            ["find", d, "-group", str(old_gid),
                             "-exec", "chgrp", "nova", "{}", "+"],
                            check=False,
                        )
            logger.info("Updated nova to UID %d and re-owned Trilio directories", NOVA_TARGET_UID)

        # TVAULT-7404 root-user experiment: contego/DMS now run as root (see
        # DATAMOVER_SYSTEMD_UNIT/DMS_SYSTEMD_UNIT), so the disk/kvm/root group
        # memberships previously granted here for socket/device access are no
        # longer needed — root already has full access to those regardless of
        # group. See nova-user-known-good-state.md for the nova-user approach
        # this replaces and how to roll back to it.

    def _install_packages(self):
        version = self.config["trilio-version"].strip()

        dm_pkg = f"{DATAMOVER_PACKAGE}={version}*" if version else DATAMOVER_PACKAGE
        dms_pkg = f"python3-trilio-dms={version}*" if version else "python3-trilio-dms"

        self._ensure_nova_user()
        subprocess.run(
            ["apt-get", "install", "-y", "--no-install-recommends",
             "fuse", "libfuse2", "nfs-common",
             "udev", "qemu-utils", "ceph-common",
             "python3-novaclient", "python3-cinderclient",
             "python3-libvirt", "python3-s3-fuse-plugin",
             dm_pkg, dms_pkg],
            check=True,
        )
        logger.info("Installed %s and python3-trilio-dms", dm_pkg)

    def _create_directories(self):
        dirs = [
            "/etc/triliovault-datamover",
            "/etc/triliovault-dms",
            "/etc/triliovault-object-store",
            "/var/log/triliovault",
            "/var/triliovault-mounts",
            "/var/triliovault",
            "/opt/triliovault",
            "/run/dms",
            "/run/dms/s3",
        ]
        for d in dirs:
            os.makedirs(d, exist_ok=True)
        # opt/triliovault owned by nova (mirrors kolla Dockerfile)
        shutil.chown("/opt/triliovault", user="nova", group="nova")
        shutil.chown("/var/triliovault-mounts", user="nova", group="nova")
        shutil.chown("/var/triliovault", user="nova", group="nova")
        os.chmod("/var/triliovault-mounts", 0o777)
        os.chmod("/var/triliovault", 0o777)
        # Fuse requires user_allow_other for DMS FUSE mounts.
        # Guard before appending — this method is called on install AND on
        # config-changed, so naively appending would duplicate the line on every
        # re-configuration, eventually corrupting the file.
        fuse_conf = "/etc/fuse.conf"
        with open(fuse_conf, "r") as f:
            fuse_content = f.read()
        if "user_allow_other" not in fuse_content:
            with open(fuse_conf, "a") as f:
                f.write("\nuser_allow_other\n")

        # TVAULT-7404 root-user experiment: contego now runs as root, so it
        # already has full access to instances/ and can create its own
        # snapshots/ subdirectory and staging tempfiles there without any
        # permission grant — the group-write chmods previously applied here
        # (for when contego ran as nova) are no longer needed. See
        # nova-user-known-good-state.md for that approach and how to roll
        # back to it.

        logger.info("Directories created")

    def _render_template(self, template_name: str, context: dict) -> str:
        """Render a Jinja2 template from src/templates/."""
        loader = jinja2.FileSystemLoader(str(TEMPLATE_DIR))
        env = jinja2.Environment(loader=loader, keep_trailing_newline=True)
        return env.get_template(template_name).render(**context)

    def _write_file(self, path: str, content: str, mode: int = 0o644):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        os.chmod(path, mode)

    # --- datamover config file rendering ---

    def _write_datamover_config(self):
        amqp = self._amqp_data()
        transport_url = (
            f"rabbit://datamover:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            # Must match dm-api's own vhost ("dmapi") — see _on_amqp_relation_joined.
            f"/dmapi"
        )
        cafile = CA_BUNDLE_COPY if os.path.exists(CA_BUNDLE_COPY) else ""
        context = {
            "transport_url": transport_url,
            "dm_config_path": DM_CONFIG_PATH,
            "debug": str(self.config["debug"]).lower(),
            "cafile": cafile,
            "rabbit_quorum_queue": str(self.config.get("rabbit-quorum-queue", True)).lower(),
            "amqp_durable_queues": str(self.config.get("amqp-durable-queues", True)).lower(),
            "ceph_client_name": self._ceph_client_name,
            "ceph_conf_path": CEPH_CONF_PATH,
            "ceph_backend_enabled": self._ceph_backend_enabled(),
        }
        self._write_file(DM_CONFIG_PATH, self._render_template("triliovault-datamover.conf.j2", context))
        logger.info("Wrote %s", DM_CONFIG_PATH)
        self._write_file(DM_LOGGING_CONF_PATH, self._render_template("datamover_logging.conf.j2", {}))
        logger.info("Wrote %s", DM_LOGGING_CONF_PATH)

    # --- DMS config file rendering ---

    def _write_dms_config(self):
        amqp = self._amqp_data()
        identity = self._identity_data()

        transport_url = (
            f"rabbit://datamover:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            # Must match dm-api's own vhost ("dmapi") — see _on_amqp_relation_joined.
            f"/dmapi"
        )
        # Use the HTTPS internal endpoint if keystone published one via traefik;
        # fall back to plain-http k8s service address for fresh deploys.
        auth_url = (
            identity.get("internal_endpoint")
            or (
                f"{identity.get('credentials_protocol', 'http')}://"
                f"{identity['credentials_host']}:{identity.get('credentials_port', '5000')}/v3"
            )
        )
        cafile = CA_BUNDLE_COPY if os.path.exists(CA_BUNDLE_COPY) else ""
        context = {
            "rabbitmq_url": transport_url,
            "node_id": socket.getfqdn(),
            "auth_url": auth_url,
            "cafile": cafile,
            "log_file": DMS_LOG_FILE,
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "rabbitmq_queue_type": "quorum" if self.config.get("rabbit-quorum-queue", True) else "classic",
            "rabbitmq_queue_durable": str(self.config.get("amqp-durable-queues", True)).lower(),
        }
        self._write_file(DMS_CONFIG_PATH, self._render_template("triliovault-dms-server.conf.j2", context))
        logger.info("Wrote %s", DMS_CONFIG_PATH)

    def _write_dms_client_config(self):
        """Write /etc/triliovault-dms/client.conf for tvault-contego DMS client.

        db_url must point to WLM database — set wlm-db-url charm config.
        Skipped with a warning if wlm-db-url is not configured.
        """
        wlm_db_url = self.config.get("wlm-db-url", "").strip()
        if not wlm_db_url:
            logger.warning("wlm-db-url not set — skipping DMS client.conf")
            return

        amqp = self._amqp_data()
        transport_url = (
            f"rabbit://datamover:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            # Must match dm-api's own vhost ("dmapi") — see _on_amqp_relation_joined.
            f"/dmapi"
        )
        context = {
            "rabbitmq_url": transport_url,
            "db_url": wlm_db_url,
            "node_id": socket.getfqdn(),
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "log_file": DMS_CLIENT_LOG_FILE,
        }
        self._write_file(DMS_CLIENT_CONF_PATH, self._render_template("triliovault-dms-client.conf.j2", context))
        logger.info("Wrote %s", DMS_CLIENT_CONF_PATH)

    # TVAULT-7404 root-user experiment: contego now runs as root (see
    # DATAMOVER_SYSTEMD_UNIT), so root always resolves in libvirtd's own
    # snap-confined passwd view and the qemu+ext:// sudo-wrapped-nc relay
    # (previously needed to make the socket-connecting peer look like root
    # while contego itself ran as nova) is no longer needed — connection_uri
    # in triliovault-datamover.conf.j2 goes back to a plain qemu+unix:// path.
    # See nova-user-known-good-state.md for that approach and how to roll
    # back to it.
    LIBVIRT_SOCKET_PATH = "/var/snap/openstack-hypervisor/common/run/libvirt/libvirt-sock"

    def _write_nova_sudoers(self):
        """Write sudoers rule for nova privsep-helper (mirrors kolla nova-sudoers).

        Pre-existing (predates the qemu+nc libvirt fix removed above) — kept
        as-is; unrelated to the root-user experiment.
        """
        sudoers_path = "/etc/sudoers.d/nova-sudoers"
        content = "nova ALL=(root) NOPASSWD: /usr/bin/privsep-helper *\n"
        os.makedirs("/etc/sudoers.d", exist_ok=True)
        with open(sudoers_path, "w") as f:
            f.write(content)
        os.chmod(sudoers_path, 0o440)
        logger.info("Wrote %s", sudoers_path)

    # --- ceph-client relation: fetch contego's own Ceph credentials ---

    def _on_ceph_broker_available(self, event):
        """Phase 1: request minimal mon-read-only access.

        We don't yet know which pools are actually in use (that requires
        querying the cluster ourselves before we have credentials for it), so
        pool discovery here goes through libvirt directly (charm hooks run as
        root, no credentials needed) rather than a ceph client call — see
        _discover_cinder_ceph_pools/_discover_nova_ceph_pool.

        This charm sends exactly ONE set-key-permissions request, ever, for a
        given pool set. interface_ceph_client's own duplicate-request check
        (CephBrokerRq._ops_equal) only compares a fixed key list — replicas,
        name, op, pg_num, group-permission, object-prefix-permissions — which
        does NOT include 'client' or 'permissions'. Two different
        set-key-permissions requests therefore always compare as "equal" to
        that check, so a second request with different content silently gets
        discarded and replaced with the first one's stale content instead of
        being sent. Concretely: don't try to "upgrade" an already-granted key
        to a different capability string later — it won't take effect.
        """
        candidates = self._discover_cinder_ceph_pools()
        nova_pool = self._discover_nova_ceph_pool()
        if nova_pool:
            candidates.add(nova_pool)

        if candidates:
            pools = sorted(candidates)
            osd_cap = ", ".join(f"allow rwx pool={p}" for p in pools)
            mon_cap = 'allow r, allow command "osd blacklist", allow command "osd blocklist"'
            permissions = ["mon", mon_cap, "osd", osd_cap]
            os.makedirs(os.path.dirname(CEPH_GRANTED_POOLS_MARKER), exist_ok=True)
            with open(CEPH_GRANTED_POOLS_MARKER, "w") as f:
                f.write("\n".join(pools))
        else:
            # No Ceph-backed Cinder volume attached and no Ceph-backed Nova
            # ephemeral config found yet — request read-only mon access only.
            # Per the note above, if pools appear later there's no way to
            # widen this same key's capability through this relation; that's
            # a known limitation of the single-request approach.
            permissions = ["mon", "allow r"]

        logger.info("Requesting ceph permissions for client=%s: %s", self._ceph_client_name, permissions)
        self.ceph.request_ceph_permissions(self._ceph_client_name, permissions)

    def _on_ceph_pools_available(self, event):
        """Fires once our one-and-only ceph-client request is satisfied."""
        data = self.ceph.get_relation_data()
        mon_hosts = data.get("mon_hosts")
        key = data.get("key")
        if not mon_hosts or not key:
            return
        self._write_ceph_conf(mon_hosts)
        self._write_ceph_keyring(key)

    def _write_ceph_conf(self, mon_hosts):
        content = (
            "[global]\n"
            f"mon host = {','.join(mon_hosts)}\n"
            "auth_cluster_required = cephx\n"
            "auth_service_required = cephx\n"
            "auth_client_required = cephx\n"
        )
        os.makedirs("/etc/ceph", exist_ok=True)
        with open(CEPH_CONF_PATH, "w") as f:
            f.write(content)
        os.chmod(CEPH_CONF_PATH, 0o644)
        logger.info("Wrote %s", CEPH_CONF_PATH)

    def _write_ceph_keyring(self, key):
        keyring_path = self._ceph_keyring_path()
        content = f"[client.{self._ceph_client_name}]\n\tkey = {key}\n"
        with open(keyring_path, "w") as f:
            f.write(content)
        os.chmod(keyring_path, 0o640)
        shutil.chown(keyring_path, group="nova")
        logger.info("Wrote %s", keyring_path)

    def _discover_cinder_ceph_pools(self) -> set:
        """Find RBD pool names actually attached to instances on this node.

        Scans every domain's live XML for network/rbd disks (Cinder-attached
        Ceph volumes) — this reflects what's genuinely in use on this compute
        node regardless of how Cinder's backend happens to be configured,
        since we have no direct relation to cinder-volume itself to ask.
        """
        pools = set()
        try:
            import libvirt
        except ImportError:
            return pools
        try:
            conn = libvirt.open(
                "qemu+unix:///system?socket="
                f"{self.LIBVIRT_SOCKET_PATH}"
            )
        except Exception as e:
            logger.warning("Cannot open libvirt connection for ceph pool discovery: %s", e)
            return pools
        try:
            for dom in conn.listAllDomains():
                try:
                    xml = dom.XMLDesc()
                except Exception:
                    continue
                root = ET.fromstring(xml)
                for disk in root.findall("./devices/disk"):
                    if disk.get("type") != "network":
                        continue
                    source = disk.find("source")
                    if source is None or source.get("protocol") not in ("rbd", "ceph"):
                        continue
                    name = source.get("name", "")
                    if "/" in name:
                        pools.add(name.split("/", 1)[0])
        finally:
            conn.close()
        return pools

    def _discover_nova_ceph_pool(self):
        """Return Nova's own ephemeral-disk RBD pool name, if it uses one.

        Only relevant when nova.conf's [libvirt] images_type is rbd — reads
        the already-synced copy of nova.conf (_sync_nova_conf), not the
        snap-internal original, since that one is root-only.
        """
        parser = configparser.ConfigParser(strict=False)
        try:
            parser.read(NOVA_CONF_COPY)
        except OSError:
            return None
        if not parser.has_section("libvirt"):
            return None
        if parser.get("libvirt", "images_type", fallback="default") != "rbd":
            return None
        return parser.get("libvirt", "images_rbd_pool", fallback="nova")

    def _ceph_backend_enabled(self) -> bool:
        """True once we have at least one pool actually granted.

        Gates the [libvirt] images_rbd_ceph_conf/rbd_user and [ceph]
        keyring_ext block in triliovault-datamover.conf.j2 — mirrors kolla-
        ansible's own cinder_backend_ceph conditional, except driven by
        confirmed pool grants rather than a static deployment variable, since
        we discover this dynamically rather than being told about it.
        """
        try:
            with open(CEPH_GRANTED_POOLS_MARKER) as f:
                return bool(f.read().split())
        except OSError:
            return False

    def _install_rootwrap_filters(self):
        """Install trilio.filters for nova rootwrap (mirrors kolla ADD trilio.filters)."""
        filters_dir = "/usr/share/nova/rootwrap"
        filters_src = pathlib.Path(__file__).parent.parent / "files" / "trilio.filters"
        if filters_src.exists():
            os.makedirs(filters_dir, exist_ok=True)
            shutil.copy2(str(filters_src), os.path.join(filters_dir, "trilio.filters"))
            logger.info("Installed trilio.filters to %s", filters_dir)
        else:
            logger.warning("trilio.filters not found in charm files/, skipping rootwrap install")

    def _write_systemd_services(self):
        """Write systemd unit files for DMS server and tvault-contego.

        Both units are not shipped by their packages (designed for kolla containers).
        Written once at install time; daemon-reload is called before service start.
        """
        units = {
            f"/lib/systemd/system/{DMS_SERVICE}.service": DMS_SYSTEMD_UNIT,
            f"/lib/systemd/system/{DATAMOVER_SERVICE}.service": DATAMOVER_SYSTEMD_UNIT,
        }
        for path, content in units.items():
            with open(path, "w") as f:
                f.write(content)
            logger.info("Wrote systemd unit %s", path)

    def _write_s3vaultfuse_config(self):
        self._write_file(S3VAULTFUSE_CONF, self._render_template("s3vaultfuse-global.conf.j2", {}))
        logger.info("Wrote %s", S3VAULTFUSE_CONF)
        self._write_file(
            OBJECT_STORE_LOGGING_CONF_PATH,
            self._render_template("object_store_logging.conf.j2", {}),
        )
        logger.info("Wrote %s", OBJECT_STORE_LOGGING_CONF_PATH)

    # Matches any cafile= line whose value starts with /var/snap/ — the snap-internal
    # path is root-only; we replace it with CA_BUNDLE_COPY which is root:nova 640.
    _SNAP_CAFILE_RE = re.compile(rb"(?m)^([ \t]*cafile[ \t]*=[ \t]*)/var/snap/[^\n]*")

    def _sync_nova_conf(self) -> bool:
        """Copy snap nova.conf to our location if content changed.

        The snap nova.conf is root:root 640 — unreadable by the nova user that
        tvault-contego runs as.  Charm hooks run as root, so we copy it to
        NOVA_CONF_COPY (root:nova 640).

        The cafile= line in [keystone_authtoken] references a snap-internal path
        (also root-only).  We rewrite it to CA_BUNDLE_COPY, which is written by
        _write_ca_cert() from the receive-ca-cert relation (root:nova 640).
        If no CA cert is available yet, the cafile= line is removed so
        keystoneauth1 falls back to the system CA trust store.

        Returns True if the file was updated, False if nothing changed.
        """
        try:
            with open(SNAP_NOVA_CONF, "rb") as f:
                snap_content = f.read()
        except OSError as e:
            logger.warning("Cannot read snap nova.conf: %s", e)
            return False

        # Patch cafile= to point to our nova-readable CA bundle (from relation).
        if os.path.exists(CA_BUNDLE_COPY):
            new_content = self._SNAP_CAFILE_RE.sub(
                rb"\g<1>" + CA_BUNDLE_COPY.encode(), snap_content
            )
        else:
            # CA not yet available — strip cafile so keystoneauth1 uses system store
            new_content = self._SNAP_CAFILE_RE.sub(b"", snap_content)

        new_hash = hashlib.sha256(new_content).hexdigest()

        try:
            with open(NOVA_CONF_COPY, "rb") as f:
                old_hash = hashlib.sha256(f.read()).hexdigest()
        except OSError:
            old_hash = None

        if new_hash == old_hash:
            # Content unchanged — still fix ownership in case nova GID changed
            if os.path.exists(NOVA_CONF_COPY):
                shutil.chown(NOVA_CONF_COPY, user="root", group="nova")
                os.chmod(NOVA_CONF_COPY, 0o640)
            return False

        os.makedirs(os.path.dirname(NOVA_CONF_COPY), exist_ok=True)
        with open(NOVA_CONF_COPY, "wb") as f:
            f.write(new_content)
        shutil.chown(NOVA_CONF_COPY, user="root", group="nova")
        os.chmod(NOVA_CONF_COPY, 0o640)
        logger.info("Synced nova.conf from snap to %s (cafile patched)", NOVA_CONF_COPY)
        return True

    def _on_update_status(self, event):
        """Detect snap nova.conf changes and restart services only when content changed."""
        if self._sync_nova_conf():
            logger.info("nova.conf changed — restarting DataMover and DMS")
            try:
                subprocess.run(
                    ["systemctl", "restart", DATAMOVER_SERVICE, DMS_SERVICE],
                    check=True,
                )
            except subprocess.CalledProcessError as e:
                self.unit.status = ops.BlockedStatus(f"Service restart failed: {e}")

    # --- service management ---

    def _restart_services(self):
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        for svc in (DATAMOVER_SERVICE, DMS_SERVICE):
            subprocess.run(["systemctl", "enable", svc], check=True)
            subprocess.run(["systemctl", "restart", svc], check=True)
            logger.info("Restarted %s", svc)


if __name__ == "__main__":
    ops.main(TrilioDataMoverSunbeamCharm)
