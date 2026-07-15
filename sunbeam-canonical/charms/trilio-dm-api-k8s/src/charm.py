#!/usr/bin/env python3
"""TrilioVault DataMover API Kubernetes charm for Sunbeam Canonical OpenStack.

Manages the dmapi service via Pebble inside a k8s pod on port 8784.
Requires wlm-service relation to trilio-wlm-k8s to obtain the WLM API endpoint.

Tested against Caracal (OpenStack 2024.1) on Sunbeam.

Relation interface notes (Sunbeam Caracal):
  - database: mysql_client interface — provider (mysql-k8s) writes into its
    *application* databag. Keys: endpoints, username, password, database.
  - amqp: rabbitmq interface — unit databag.
    Keys: hostname (or host), port, password, vhost, username.
  - identity-service: keystone interface — unit databag.
    Keys: service_host, service_port, service_protocol, service_username,
          service_password, service_tenant.
  - wlm-service: custom interface — remote app databag.
    Keys: wlm-api-url.
"""

import configparser
import io
import logging

import ops

logger = logging.getLogger(__name__)

CONTAINER = "trilio-dm-api"
CONFIG_PATH = "/etc/triliovault-datamover/triliovault-datamover-api.conf"
DMAPI_LOGGING_CONF_PATH = "/etc/triliovault-datamover/datamover_api_logging.conf"
DMS_CLIENT_CONF = "/etc/triliovault-dms/client.conf"
LOG_DIR = "/var/log/triliovault"

# Python logging config pushed into the container by the charm (not baked into the image).
# Matches the RHOSO18 _datamover_api_logging_conf.tpl reference.
DMAPI_LOGGING_CONF = """\
[loggers]
keys = root,dmapi

[handlers]
keys = dmapi,stdout,stderr,null

[formatters]
keys = default,advanced,default-utc,advanced-utc

[logger_root]
level = INFO
handlers = null

[logger_dmapi]
level = INFO
handlers = dmapi,stdout,stderr
qualname = dmapi

[handler_dmapi]
class = logging.handlers.RotatingFileHandler
args = ('/var/log/triliovault/triliovault-datamover-api.log','a',25000000,20)
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
class = dmapi.common.log.UTCFormatter
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced-utc]
class = dmapi.common.log.UTCFormatter
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_default]
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced]
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z
"""
DMAPI_PORT = 8784
# Service type/name confirmed from `openstack endpoint list` — same on all platforms:
#   Service Name=dmapi  Service Type=datamover
DMAPI_SERVICE_TYPE = "datamover"
DMAPI_SERVICE_NAME = "dmapi"


class TrilioDmApiK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_dm_api_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.leader_elected, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._configure)
        for rel in ("database", "amqp", "identity_service", "wlm_service"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_changed"), self._configure
            )
        self.framework.observe(
            self.on.ingress_internal_relation_joined, self._on_ingress_relation_joined
        )
        self.framework.observe(self.on.amqp_relation_joined, self._on_amqp_relation_joined)
        self.framework.observe(self.on.database_relation_joined, self._on_database_relation_joined)
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._configure
        )

    # --- event handlers ---

    def _on_pebble_ready(self, event):
        self._configure(event)

    def _on_ingress_relation_joined(self, event):
        self._publish_ingress(event.relation)

    def _on_amqp_relation_joined(self, event):
        """Write rabbitmq requirer credentials so rabbitmq-k8s provisions the user/vhost."""
        event.relation.data[self.unit]["username"] = "dmapi"
        event.relation.data[self.unit]["vhost"] = "dmapi"

    def _on_database_relation_joined(self, event):
        """Write mysql requirer database name so mysql-k8s provisions the database."""
        if self.unit.is_leader():
            event.relation.data[self.app]["database"] = "datamover"

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
        self._write_ca_cert(container)
        if self.unit.is_leader():
            self._db_sync(container)
        self._update_pebble_layer(container)
        self.unit.open_port("tcp", DMAPI_PORT)

        if self.unit.is_leader():
            self._register_keystone_service()

        self.unit.status = ops.ActiveStatus("DM-API ready")

    # --- relation data helpers ---

    def _missing_relations(self):
        missing = []
        if not self._db_data():
            missing.append("database")
        if not self._amqp_data():
            missing.append("amqp")
        if not self._identity_data():
            missing.append("identity-service")
        if not self._wlm_data():
            missing.append("wlm-service")
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
        """rabbitmq interface: unit databag. Accept both hostname and host keys."""
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
        """keystone interface: unit databag."""
        rel = self.model.get_relation("identity-service")
        if not rel:
            return None
        for unit in rel.units:
            d = rel.data[unit]
            if d.get("service_host") and d.get("service_password"):
                return d
        return None

    def _wlm_data(self):
        """wlm-service: trilio-wlm-k8s writes wlm-api-url and wlm-db-url into its app databag.

        wlm-db-url is WLM's database connection string, required by the DMS client
        running inside DMAPI to connect to WLM's workload state database.
        """
        rel = self.model.get_relation("wlm-service")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        if d.get("wlm-api-url") and d.get("wlm-db-url"):
            return d
        return None

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
        """Run DMAPI database migrations (idempotent; leader only).

        DMAPI uses dmapi-dbsync (not dmapi-manage db_sync). The tool reads the
        database connection from [database].connection in CONFIG_PATH.
        """
        container.exec(
            ["/usr/bin/dmapi-dbsync", "--config-file", CONFIG_PATH],
        ).wait()
        logger.info("dmapi-dbsync completed")

    # --- config file rendering ---

    def _write_config(self, container):
        db = self._db_data()
        amqp = self._amqp_data()
        identity = self._identity_data()
        wlm = self._wlm_data()

        # mysql_client: endpoints is "host:port" (may be comma-separated for HA)
        endpoint = db["endpoints"].split(",")[0].strip()
        db_host, _, db_port = endpoint.partition(":")
        db_port = db_port or "3306"
        db_url = (
            f"mysql+pymysql://{db['username']}:{db['password']}"
            f"@{db_host}:{db_port}/{db['database']}"
        )

        transport_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
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
            "log_config_append": DMAPI_LOGGING_CONF_PATH,
            "debug": str(self.config["debug"]).lower(),
            "wlm_endpoint": wlm["wlm-api-url"],
            # k8s: bind on all pod interfaces; service DNS handles intra-cluster routing
            "my_ip": "0.0.0.0",
            "dmapi_listen": "0.0.0.0",
            "dmapi_listen_port": str(DMAPI_PORT),
            "dmapi_link_prefix": f"http://{self.app.name}:{DMAPI_PORT}",
            "dmapi_enabled_ssl_apis": "",
            "dmapi_enabled_apis": "dmapi",
            "bindir": "/usr/bin",
            "dmapi_workers": str(self.config["api-workers"]),
        }
        cfg["database"] = {
            "connection": db_url,
        }
        cfg["keystone_authtoken"] = {
            "auth_url": auth_url,
            # www_authenticate_uri is required by keystonemiddleware for token validation.
            # Without it the middleware cannot build the Keystone challenge URL and
            # returns 401 on every authenticated request.
            "www_authenticate_uri": auth_url,
            "username": identity.get("service_username", "dmapi"),
            "password": identity["service_password"],
            "project_name": identity.get("service_tenant", "services"),
            "user_domain_name": "Default",
            "project_domain_name": "Default",
            "auth_type": "password",
            "service_token_roles_required": "True",
        }
        cfg["dmapi"] = {}
        cfg["oslo_messaging_notifications"] = {
            "driver": "noop",
            "transport_url": transport_url,
        }
        cfg["oslo_messaging_rabbit"] = {
            "heartbeat_in_pthread": "False",
        }
        cfg["oslo_middleware"] = {
            "enable_proxy_headers_parsing": "True",
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(CONFIG_PATH, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", CONFIG_PATH)
        container.push(DMAPI_LOGGING_CONF_PATH, DMAPI_LOGGING_CONF, make_dirs=True)
        logger.info("Wrote %s", DMAPI_LOGGING_CONF_PATH)

    def _write_dms_client_config(self, container):
        """Write DMS client config for the trilio-dms client library inside DMAPI.

        Uses DMAPI's own RabbitMQ transport URL but WLM's database URL — the DMS
        client connects to WLM's database for workload state, not DMAPI's own DB.
        WLM publishes its DB URL via the wlm-service relation as 'wlm-db-url'.
        """
        amqp = self._amqp_data()
        wlm = self._wlm_data()

        rabbitmq_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
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
            "db_url": wlm.get("wlm-db-url", ""),
            "node_id": self.unit.name.replace("/", "-"),
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(DMS_CLIENT_CONF, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", DMS_CLIENT_CONF)

    # --- Pebble layer ---

    def _update_pebble_layer(self, container):
        layer = ops.pebble.Layer({
            "summary": "TrilioVault DM-API",
            "services": {
                "dmapi-api": {
                    "override": "replace",
                    "summary": "DataMover API",
                    "command": f"/usr/bin/dmapi-api --config-file {CONFIG_PATH}",
                    "startup": "enabled",
                    "environment": self._get_ca_bundle_env(),
                }
            },
        })
        container.add_layer(CONTAINER, layer, combine=True)
        container.replan()
        logger.info("Pebble layer applied for dmapi-api")

    # --- endpoint / ingress publishing ---

    def _register_keystone_service(self):
        """Write DMAPI endpoint registration data into the identity-service relation.

        Sunbeam keystone-k8s reads these from the requirer app databag and registers
        the service + endpoints in the Keystone catalog so clients can discover the
        DMAPI URL via the service catalog.
        """
        rel = self.model.get_relation("identity-service")
        if not rel:
            return
        internal_url = f"http://{self.app.name}:{DMAPI_PORT}/v2"
        rel.data[self.app].update({
            "service_name": DMAPI_SERVICE_NAME,
            "service_type": DMAPI_SERVICE_TYPE,
            "public_url": internal_url,
            "internal_url": internal_url,
            "admin_url": internal_url,
            "region": "RegionOne",
        })

    def _publish_ingress(self, rel):
        """Write traefik_k8s v2 ingress requirer data so traefik routes external
        traffic to the DMAPI service.
        """
        if not self.unit.is_leader():
            return
        rel.data[self.app].update({
            "model": self.model.name,
            "name": self.app.name,
            "port": str(DMAPI_PORT),
            "scheme": "http",
            "strip-prefix": "false",
            "redirect-https": "false",
        })


if __name__ == "__main__":
    ops.main(TrilioDmApiK8sCharm)
