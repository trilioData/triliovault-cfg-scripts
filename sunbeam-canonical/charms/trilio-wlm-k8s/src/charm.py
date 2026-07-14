#!/usr/bin/env python3
"""TrilioVault WorkloadManager Kubernetes charm for Sunbeam Canonical OpenStack.

Manages four WLM microservices via Pebble inside a single k8s pod:
  wlm-api, wlm-workloads, wlm-scheduler, wlm-cron (leader-only singleton).

Tested against Caracal (OpenStack 2024.1) on Sunbeam.

Relation interface notes (Sunbeam Caracal):
  - database: mysql_client interface — provider (mysql-k8s) writes data into
    its *application* databag. Keys: endpoints, username, password, database.
  - amqp: rabbitmq interface — provider (rabbitmq-k8s) writes into unit databag.
    Keys: hostname (or host), port, password, vhost, username.
  - identity-service: keystone interface — unit databag.
    Keys: service_host, service_port, service_protocol, service_username,
          service_password, service_tenant.
  - ingress-internal / ingress-public: traefik_k8s v2 ingress interface.
    Requirer writes a JSON blob under "data" key in the app databag.
"""

import configparser
import io
import logging

import ops

logger = logging.getLogger(__name__)

CONTAINER = "trilio-wlm"
CONFIG_PATH = "/etc/triliovault-wlm/triliovault-wlm.conf"
DMS_CLIENT_CONF = "/etc/triliovault-dms/client.conf"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
LOG_DIR = "/var/log/triliovault"
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


class TrilioWlmK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_wlm_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.leader_elected, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._configure)
        for rel in ("database", "amqp", "identity_service"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_changed"), self._configure
            )
        self.framework.observe(self.on.wlm_service_relation_joined, self._on_wlm_service_joined)
        for rel in ("ingress_internal", "ingress_public"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_joined"), self._on_ingress_relation_joined
            )

    # --- event handlers ---

    def _on_pebble_ready(self, event):
        self._configure(event)

    def _on_wlm_service_joined(self, event):
        if self.unit.is_leader():
            self._publish_wlm_service_data()

    def _on_ingress_relation_joined(self, event):
        self._publish_ingress(event.relation)

    def _configure(self, event):
        container = self.unit.get_container(CONTAINER)
        if not container.can_connect():
            self.unit.status = ops.WaitingStatus("Waiting for Pebble in workload container")
            event.defer()
            return

        missing = self._missing_relations()
        if missing:
            self.unit.status = ops.WaitingStatus(f"Waiting for: {', '.join(missing)}")
            return

        self._write_config(container)
        self._write_dms_client_config(container)
        self._update_pebble_layer(container)
        # Expose WLM_PORT so Juju creates the k8s Service port entry.
        # Without this, intra-cluster traffic to wlm-api cannot reach the pod.
        self.unit.open_port("tcp", WLM_PORT)

        if self.unit.is_leader():
            self._publish_wlm_service_data()
            self._register_keystone_service()

        self.unit.status = ops.ActiveStatus("WLM ready")

    # --- relation data helpers ---

    def _missing_relations(self):
        missing = []
        if not self._db_data():
            missing.append("database")
        if not self._amqp_data():
            missing.append("amqp")
        if not self._identity_data():
            missing.append("identity-service")
        return missing

    def _db_data(self):
        """mysql_client interface: provider writes into its application databag.

        Keys: endpoints (host:port), username, password, database.
        """
        rel = self.model.get_relation("database")
        if not rel:
            return None
        for app in rel.apps:
            if app is self.app:
                continue
            d = rel.data[app]
            if d.get("endpoints") and d.get("password"):
                return d
        return None

    def _amqp_data(self):
        """rabbitmq interface: provider writes into unit databag.

        rabbitmq-k8s uses 'hostname'; older rabbitmq uses 'host'. Accept both.
        """
        rel = self.model.get_relation("amqp")
        if not rel:
            return None
        for unit in rel.units:
            d = rel.data[unit]
            host = d.get("hostname") or d.get("host")
            if host and d.get("password"):
                return {**dict(d), "host": host}
        return None

    def _identity_data(self):
        """keystone interface: unit databag keys service_host, service_password."""
        rel = self.model.get_relation("identity-service")
        if not rel:
            return None
        for unit in rel.units:
            d = rel.data[unit]
            if d.get("service_host") and d.get("service_password"):
                return d
        return None

    # --- config file rendering ---

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
            f"rabbit://{amqp.get('username', 'wlm')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'wlm')}"
        )
        auth_url = (
            f"{identity.get('service_protocol', 'http')}://"
            f"{identity['service_host']}:{identity.get('service_port', '5000')}/v3"
        )

        cfg = configparser.ConfigParser()

        cfg["DEFAULT"] = {
            "transport_url": transport_url,
            "auth_strategy": "keystone",
            "log_dir": LOG_DIR,
            "debug": str(self.config["debug"]).lower(),
            "vault_data_directory": "/var/triliovault-mounts",
            "vault_data_directory_old": "/var/triliovault",
            "state_path": "/var/lib/workloadmgr",
            # Explicit port (8781) so the binary binds on the same port open_port()
            # advertises and that is registered as the Keystone endpoint port.
            "osapi_workloads_listen_port": str(WLM_PORT),
        }
        cfg["database"] = {
            "connection": db_url,
        }
        cfg["keystone_authtoken"] = {
            "auth_url": auth_url,
            "www_authenticate_uri": auth_url,
            "username": identity.get("service_username", "wlm"),
            "password": identity["service_password"],
            "project_name": identity.get("service_tenant", "services"),
            "user_domain_name": "Default",
            "project_domain_name": "Default",
            "auth_type": "password",
            "service_token_roles_required": "True",
        }
        cfg["wlm"] = {
            "api_workers": str(self.config["api-workers"]),
        }
        cfg["barbican"] = {
            "encryption_support": "true",
        }
        cfg["global_job_scheduler"] = {
            "misfire_grace_time": "600",
        }
        cfg["s3fuse_sys_admin"] = {
            "helper_command": (
                "sudo /usr/bin/workloadmgr-rootwrap"
                " /etc/triliovault-wlm/rootwrap.conf privsep-helper"
            ),
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(CONFIG_PATH, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", CONFIG_PATH)

    def _write_dms_client_config(self, container):
        """Write DMS client config for the trilio-dms client library inside WLM.

        Contains only static pool/logging tuning — matching RHOSO18. The DMS client
        library inherits RabbitMQ and DB connections from triliovault-wlm.conf
        (transport_url and database.connection), so those are not repeated here.
        """
        cfg = configparser.ConfigParser()
        cfg["client"] = {
            "request_timeout": "60",
            "log_level": "INFO",
            "log_file": "/var/log/triliovault/trilio-dms-client.log",
            "log_max_bytes": "26214400",
            "log_backup_count": "5",
            "db_pool_size": "20",
            "db_max_overflow": "40",
            "db_pool_recycle": "3600",
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(DMS_CLIENT_CONF, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", DMS_CLIENT_CONF)

    # --- Pebble layer ---

    def _build_pebble_layer(self):
        cmd_base = f"/usr/bin/{{}} --config-file {CONFIG_PATH}"
        services = {
            "wlm-api": {
                "override": "replace",
                "summary": "WLM API",
                "command": cmd_base.format("wlm-api"),
                "startup": "enabled",
            },
            "wlm-workloads": {
                "override": "replace",
                "summary": "WLM Workloads",
                "command": cmd_base.format("wlm-workloads"),
                "startup": "enabled",
            },
            "wlm-scheduler": {
                "override": "replace",
                "summary": "WLM Scheduler",
                "command": cmd_base.format("wlm-scheduler"),
                "startup": "enabled",
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
            "command": cmd_base.format("wlm-cron"),
            "startup": "enabled" if self.unit.is_leader() else "disabled",
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
        if rel:
            rel.data[self.app]["wlm-api-url"] = f"http://{self.app.name}:{WLM_PORT}"

    def _register_keystone_service(self):
        """Write WLM endpoint registration data into the identity-service relation.

        Sunbeam keystone-k8s reads these fields from the requirer app databag and
        registers the service + endpoints in the Keystone service catalog. Without
        this the service user is created but no endpoint appears in `openstack catalog
        list`, so external clients cannot discover the WLM URL.
        """
        rel = self.model.get_relation("identity-service")
        if not rel:
            return
        internal_url = WLM_ENDPOINT_TEMPLATE.format(f"http://{self.app.name}:{WLM_PORT}")
        rel.data[self.app].update({
            "service_name": WLM_SERVICE_NAME,
            "service_type": WLM_SERVICE_TYPE,
            "public_url": internal_url,
            "internal_url": internal_url,
            "admin_url": internal_url,
            "region": "RegionOne",
        })

    def _publish_ingress(self, rel):
        """Write traefik_k8s v2 ingress requirer data so traefik routes external
        traffic to this application.

        Uses individual databag keys matching the traefik-k8s ingress v2 interface
        spec. Traefik reads model+name to build the routing rule and port to select
        the backend service port.
        """
        if not self.unit.is_leader():
            return
        rel.data[self.app].update({
            "model": self.model.name,
            "name": self.app.name,
            "port": str(WLM_PORT),
            "scheme": "http",
            "strip-prefix": "false",
            "redirect-https": "false",
        })


if __name__ == "__main__":
    ops.main(TrilioWlmK8sCharm)
