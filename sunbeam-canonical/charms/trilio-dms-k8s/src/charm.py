#!/usr/bin/env python3
"""TrilioVault Dynamic Mount Service (DMS) Kubernetes charm for Sunbeam.

Runs the trilio-dms-server on the control plane as a Pebble-managed process.

DMS is a mount-coordination daemon — it handles NFS and S3 mount/unmount
operations on behalf of WLM and DMAPI. Communication is via RabbitMQ (no
HTTP listener). A second DMS server instance runs on every compute node,
managed by the trilio-data-mover machine subordinate charm.

Relation interface notes (Sunbeam Caracal):
  - amqp: rabbitmq interface — unit databag.
    Keys: hostname (or host), port, password, vhost, username.
  - identity-service: keystone interface — unit databag.
    Keys: service_host, service_port, service_protocol.
"""

import configparser
import io
import logging

import ops

logger = logging.getLogger(__name__)

CONTAINER = "trilio-dms"
SERVER_CONF = "/etc/triliovault-dms/server.conf"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
OBJECT_STORE_LOGGING_CONF_PATH = "/etc/triliovault-object-store/object_store_logging.conf"
LOG_FILE = "/var/log/triliovault/trilio-dms-server.log"

# Python logging config referenced by s3vaultfuse via log_config_append.
# Pushed into the container by the charm — not baked into the Docker image.
# Content matches the kolla-ansible reference.
OBJECT_STORE_LOGGING_CONF = """\
[loggers]
keys = root

[handlers]
keys = s3fuse,stdout,stderr,null

[formatters]
keys = default,advanced,default-utc,advanced-utc

[logger_root]
level = INFO
handlers = s3fuse,stdout

[handler_s3fuse]
class = logging.handlers.RotatingFileHandler
args = ('/var/log/triliovault/triliovault-object-store.log','a',25000000,20)
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
class = s3fuse.log.UTCFormatter
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced-utc]
class = s3fuse.log.UTCFormatter
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_default]
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced]
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z
"""


class TrilioDmsK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_dms_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._configure)
        for rel in ("amqp", "identity_service"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_changed"), self._configure
            )
        self.framework.observe(self.on.amqp_relation_joined, self._on_amqp_relation_joined)
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._configure
        )

    def _on_pebble_ready(self, event):
        self._configure(event)

    def _on_amqp_relation_joined(self, event):
        """Write rabbitmq requirer credentials so rabbitmq-k8s provisions the user/vhost.

        DMS uses the same vhost as DMAPI since they communicate via shared RabbitMQ queues.
        """
        event.relation.data[self.unit]["username"] = "dmapi"
        event.relation.data[self.unit]["vhost"] = "dmapi"

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
        self._write_s3vaultfuse_config(container)
        self._write_ca_cert(container)
        self._update_pebble_layer(container)
        self.unit.status = ops.ActiveStatus("DMS server running")

    def _missing_relations(self):
        missing = []
        if not self._amqp_data():
            missing.append("amqp")
        if not self._identity_data():
            missing.append("identity-service")
        return missing

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
            # Guard on both host AND password — host can arrive before password
            # during relation setup, which would write a config with an empty
            # password and cause auth failure at DMS server startup.
            if d.get("service_host") and d.get("service_password"):
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
        """Return env dict with REQUESTS_CA_BUNDLE if a CA cert is configured."""
        if self._get_ca_cert():
            return {"REQUESTS_CA_BUNDLE": "/usr/local/share/ca-certificates/ca-bundle.pem"}
        return {}

    def _write_ca_cert(self, container):
        """Write CA bundle to container and run update-ca-certificates."""
        ca_cert = self._get_ca_cert()
        if not ca_cert:
            return
        ca_path = "/usr/local/share/ca-certificates/ca-bundle.pem"
        container.push(ca_path, ca_cert, make_dirs=True)
        container.exec(["update-ca-certificates"]).wait()
        logger.info("CA bundle written to container")

    def _write_config(self, container):
        amqp = self._amqp_data()
        identity = self._identity_data()

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
        cfg["server"] = {
            "rabbitmq_url": transport_url,
            "auth_url": auth_url,
            # Use Juju unit name as stable node_id. socket.gethostname() returns the
            # k8s pod name which changes on every reschedule/restart, causing DMS to
            # register as a new cluster node each time. The Juju unit name (e.g.
            # trilio-dms-k8s-0) is stable for the lifetime of the unit.
            "node_id": self.unit.name.replace("/", "-"),
            "log_file": LOG_FILE,
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "log_max_bytes": "26214400",
            "log_backup_count": "5",
            "s3vaultfuse_bin": "/usr/bin/s3vaultfuse.py",
            "rootwrap_bin": "/usr/bin/trilio-dms-rootwrap",
            "rootwrap_conf": "/etc/triliovault-dms/rootwrap.conf",
            "worker_threads": str(self.config["worker-threads"]),
            "barbican_ssl_verify": "True",
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(SERVER_CONF, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", SERVER_CONF)

    def _write_s3vaultfuse_config(self, container):
        content = (
            "[DEFAULT]\n"
            "vault_storage_type = s3\n"
            "\n"
            "vault_s3_max_pool_connections = 50\n"
            "vault_s3_read_timeout = 30\n"
            "vault_s3_max_attempts = 3\n"
            "vault_s3_auth_version = DEFAULT\n"
            "vault_s3_signature_version = default\n"
            "\n"
            "vault_s3_ssl = True\n"
            "vault_s3_ssl_verify = True\n"
            "vault_s3_region_name = us-east-1\n"
            "\n"
            "vault_segment_size = 33554432\n"
            "vault_cache_size = 16\n"
            "queue_depth = 100\n"
            "worker_pool_size = 10\n"
            "vault_retry_count = 2\n"
            "\n"
            "vault_enable_threadpool = True\n"
            "vault_threaded_filesystem = True\n"
            "max_uploads_pending = 20\n"
            "\n"
            "vault_logging_level = error\n"
            "log_file = /var/log/triliovault/triliovault-object-store.log\n"
            "log_config_append = /etc/triliovault-object-store/object_store_logging.conf\n"
            "trace_function_calls = False\n"
            "vault_cache_username = nova\n"
            "\n"
            "bucket_object_lock = False\n"
            "use_manifest_suffix = False\n"
            "azure_immutability_enabled = False\n"
            "metadata_cache_max_items = 32\n"
            "\n"
            "[s3fuse_sys_admin]\n"
            "helper_command = sudo /usr/bin/trilio-dms-rootwrap"
            " /etc/triliovault-dms/rootwrap.conf privsep-helper\n"
        )
        container.push(S3VAULTFUSE_CONF, content, make_dirs=True)
        logger.info("Wrote %s", S3VAULTFUSE_CONF)
        container.push(OBJECT_STORE_LOGGING_CONF_PATH, OBJECT_STORE_LOGGING_CONF, make_dirs=True)
        logger.info("Wrote %s", OBJECT_STORE_LOGGING_CONF_PATH)

    def _update_pebble_layer(self, container):
        layer = ops.pebble.Layer({
            "summary": "TrilioVault DMS server",
            "services": {
                "trilio-dms-server": {
                    "override": "replace",
                    "summary": "DMS server",
                    "command": (
                        f"/usr/bin/python3 /usr/bin/trilio-dms-server"
                        f" --config-file {SERVER_CONF}"
                    ),
                    "startup": "enabled",
                    "environment": self._get_ca_bundle_env(),
                }
            },
        })
        container.add_layer(CONTAINER, layer, combine=True)
        container.replan()
        logger.info("Pebble layer applied for trilio-dms-server")


if __name__ == "__main__":
    ops.main(TrilioDmsK8sCharm)
