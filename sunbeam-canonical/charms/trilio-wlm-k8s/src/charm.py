#!/usr/bin/env python3
"""TrilioVault WorkloadManager Kubernetes charm for Sunbeam Canonical OpenStack.

Manages four WLM microservices via Pebble inside a single k8s pod:
  wlm-api, wlm-workloads, wlm-scheduler, wlm-cron (leader-only singleton).

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

import configparser
import io
import json
import logging
import socket

import ops

logger = logging.getLogger(__name__)

CONTAINER = "trilio-wlm"
CONFIG_PATH = "/etc/triliovault-wlm/triliovault-wlm.conf"
WLM_LOGGING_CONF_PATH = "/etc/triliovault-wlm/wlm_logging.conf"
DMS_CLIENT_CONF = "/etc/triliovault-dms/client.conf"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
LOG_DIR = "/var/log/triliovault"

# Python logging config pushed into the container by the charm (not baked into the image).
# Matches the RHOSO18 _wlm_logging_conf.tpl reference.
WLM_LOGGING_CONF = """\
[loggers]
keys = root, workloadmgr-api, workloadmgr-workloads, workloadmgr-cron, workloadmgr-scheduler

[handlers]
keys = stdout,stderr,null, workloadmgr-api, workloadmgr-workloads, workloadmgr-scheduler, workloadmgr-cron

[formatters]
keys = default,advanced,default-utc,advanced-utc

[logger_root]
level = INFO
handlers = null

[logger_workloadmgr-cron]
level = INFO
handlers = workloadmgr-cron,stdout,stderr
qualname = workloadmgr-cron

[logger_workloadmgr-scheduler]
level = INFO
handlers = workloadmgr-scheduler,stdout,stderr
qualname = workloadmgr-scheduler

[logger_workloadmgr-workloads]
level = INFO
handlers = workloadmgr-workloads,stdout,stderr
qualname = workloadmgr-workloads

[logger_workloadmgr-api]
level = INFO
handlers = workloadmgr-api,stdout,stderr
qualname = workloadmgr-api

[handler_workloadmgr-api]
class = workloadmgr.concurrent_log_handler.ConcurrentRotatingFileHandler
args = ('/var/log/triliovault/triliovault-wlm-api.log','a', 25000000,20)
formatter = advanced-utc

[handler_workloadmgr-cron]
class = workloadmgr.concurrent_log_handler.ConcurrentRotatingFileHandler
args = ('/var/log/triliovault/triliovault-wlm-cron.log','a', 25000000,20)
formatter = advanced-utc

[handler_workloadmgr-scheduler]
class = workloadmgr.concurrent_log_handler.ConcurrentRotatingFileHandler
args = ('/var/log/triliovault/triliovault-wlm-scheduler.log','a', 25000000,20)
formatter = advanced-utc

[handler_workloadmgr-workloads]
class = workloadmgr.concurrent_log_handler.ConcurrentRotatingFileHandler
args = ('/var/log/triliovault/triliovault-wlm-workloads.log','a', 25000000,20)
formatter = advanced-utc

[handler_stderr]
class = StreamHandler
args = (sys.stderr,)
formatter = default

[handler_stdout]
class = StreamHandler
args = (sys.stdout,)
formatter = advanced

[handler_null]
class = NullHandler
formatter = default
args = ()

[formatter_default-utc]
class = workloadmgr.openstack.common.log.UTCFormatter
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced-utc]
class = workloadmgr.openstack.common.log.UTCFormatter
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_default]
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced]
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z
"""
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
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.leader_elected, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._on_upgrade_charm)
        for rel in ("database", "amqp", "identity_service"):
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
        self.framework.observe(self.on.database_relation_joined, self._on_database_relation_joined)
        self.framework.observe(
            self.on.identity_service_relation_joined,
            self._on_identity_service_relation_joined,
        )
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._configure
        )

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

    def _on_database_relation_joined(self, event):
        """Write mysql requirer database name so mysql-k8s provisions the database."""
        if self.unit.is_leader():
            event.relation.data[self.app]["database"] = "workloadmgr"

    def _on_identity_service_relation_joined(self, event):
        """Write keystone service registration so keystone creates the service endpoints."""
        self._register_keystone_service()

    def _send_relation_requests(self):
        """Write requirer data to all relations. Idempotent — safe to call on every configure.

        Handles the case where relation-joined fired before the charm was working.
        """
        if not self.unit.is_leader():
            return
        amqp_rel = self.model.get_relation("amqp")
        if amqp_rel:
            amqp_rel.data[self.app]["username"] = "workloadmgr"
            amqp_rel.data[self.app]["vhost"] = "workloadmgr"
        db_rel = self.model.get_relation("database")
        if db_rel and not db_rel.data[self.app].get("database"):
            db_rel.data[self.app]["database"] = "workloadmgr"
        ks_rel = self.model.get_relation("identity-service")
        if ks_rel and not ks_rel.data[self.app].get("service-endpoints"):
            self._register_keystone_service()

    def _configure(self, event):
        self._send_relation_requests()
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
        self._write_ca_cert(container)
        # Run DB migrations before starting services (idempotent — safe on every leader call).
        if self.unit.is_leader():
            self._db_sync(container)
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

    def _get_ca_bundle_env(self):
        """Return env dict with REQUESTS_CA_BUNDLE when a CA cert is configured."""
        if self._get_ca_cert():
            return {"REQUESTS_CA_BUNDLE": "/usr/local/share/ca-certificates/ca-bundle.pem"}
        return {}

    def _write_ca_cert(self, container):
        """Write CA bundle into the container and refresh the system trust store."""
        ca_cert = self._get_ca_cert()
        if not ca_cert:
            return
        container.push(
            "/usr/local/share/ca-certificates/ca-bundle.pem",
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

        cfg = configparser.ConfigParser()

        cfg["DEFAULT"] = {
            "transport_url": transport_url,
            "auth_strategy": "keystone",
            "log_dir": LOG_DIR,
            # Write to stderr in addition to the log file so Pebble captures output
            # and `kubectl logs` works without exec-ing into the container.
            "use_stderr": "true",
            "log_config_append": WLM_LOGGING_CONF_PATH,
            "debug": str(self.config["debug"]).lower(),
            "vault_data_directory": "/var/triliovault-mounts",
            "vault_data_directory_old": "/var/triliovault",
            "state_path": "/var/lib/workloadmgr",
            # Explicit port (8781) so the binary binds on the same port open_port()
            # advertises and that is registered as the Keystone endpoint port.
            "osapi_workloads_listen_port": str(WLM_PORT),
            # k8s: bind on all pod interfaces; service DNS handles intra-cluster routing
            "my_ip": "0.0.0.0",
            "osapi_workloads_listen": "0.0.0.0",
            "triliovault_hostnames": "0.0.0.0",
            "config_status": "configured",
            "rootwrap_config": "/etc/triliovault-wlm/rootwrap.conf",
            "wlm_rootwrap": "/usr/bin/workloadmgr-rootwrap",
            "api_paste_config": "/etc/triliovault-wlm/api-paste.ini",
            "triliovault_user_domain_id": "default",
            "region_name_for_services": self.config["region"],
            "global_job_scheduler_override": "False",
            "api_workers": str(self.config["api-workers"]),
            "workloads_workers": str(self.config["workloads-workers"]),
            "glance_production_api_servers": self.config["glance-endpoint"],
            "glance_api_version": "2",
            "keystone_endpoint_url": auth_url,
            "keystone_auth_version": "3",
            "nova_admin_auth_url": auth_url,
            "nova_production_endpoint_template": self.config["nova-endpoint"],
            "neutron_admin_auth_url": auth_url,
            "neutron_production_url": self.config["neutron-endpoint"],
            "cinder_production_endpoint_template": self.config["cinder-endpoint"],
            "taskflow_path": "/var/lib/workloadmgr/taskflow",
            "taskflow_max_cache_size": "1024",
            "rabbit_virtual_host": amqp.get("vhost", "workloadmgr"),
            "compute_driver": "libvirt.LibvirtDriver",
            "max_wait_for_upload": "48",
            "vault_storage_das_device": "none",
            "vault_enable_threadpool": "True",
            "vault_s3_support_empty_dir": "False",
            "neutron_api_insecure": "False",
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
        cfg["wlm"] = {}
        # alembic reads sqlalchemy.url from this section for `alembic upgrade head`.
        # script_location points to the WLM migration repo baked into the package.
        cfg["alembic"] = {
            "script_location": "/usr/share/workloadmgr/migrate_repo",
            "version_locations": "/usr/share/workloadmgr/migrate_repo/versions",
            "sqlalchemy.url": db_url,
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
        cfg["clients"] = {
            "client_retry_limit": "3",
            "endpoint_type": "internal",
        }
        cfg["oslo_messaging_rabbit"] = {
            "heartbeat_in_pthread": "False",
        }
        cfg["filesearch"] = {
            "process_timeout": "300",
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(CONFIG_PATH, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", CONFIG_PATH)
        container.push(WLM_LOGGING_CONF_PATH, WLM_LOGGING_CONF, make_dirs=True)
        logger.info("Wrote %s", WLM_LOGGING_CONF_PATH)

    def _write_dms_client_config(self, container):
        """Write DMS client config for the trilio-dms client library inside WLM."""
        amqp = self._amqp_data()
        db = self._db_data()

        endpoint = db["endpoints"].split(",")[0].strip()
        db_host, _, db_port = endpoint.partition(":")
        db_port = db_port or "3306"
        db_url = (
            f"mysql+pymysql://{db['username']}:{db['password']}"
            f"@{db_host}:{db_port}/{db['database']}"
        )
        rabbitmq_url = (
            f"rabbit://{amqp.get('username', 'workloadmgr')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'workloadmgr')}"
        )

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
            "rabbitmq_url": rabbitmq_url,
            "db_url": db_url,
            "node_id": self.unit.name.replace("/", "-"),
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(DMS_CLIENT_CONF, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", DMS_CLIENT_CONF)

    # --- Pebble layer ---

    def _build_pebble_layer(self):
        # Binaries are named workloadmgr-* (confirmed from the installed package).
        # The Pebble service names (keys) are kept as wlm-* for readability.
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
