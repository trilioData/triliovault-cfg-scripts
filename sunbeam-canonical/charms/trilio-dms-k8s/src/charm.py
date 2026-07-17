#!/usr/bin/env python3
"""TrilioVault Dynamic Mount Service (DMS) Kubernetes charm for Sunbeam.

Runs the trilio-dms-server on the control plane as a Pebble-managed process.

DMS is a mount-coordination daemon — it handles NFS and S3 mount/unmount
operations on behalf of WLM and DMAPI. Communication is via RabbitMQ (no
HTTP listener). A second DMS server instance runs on every compute node,
managed by the trilio-data-mover machine subordinate charm.

DMS does not register with Keystone and has no Keystone service user.
The Keystone auth_url (used in server.conf for Barbican token validation)
is supplied via the keystone-endpoint config option.

Relation interface notes (Sunbeam Caracal):
  - amqp: rabbitmq interface — requirer writes username/vhost to its *app* databag
    (leader only); provider responds with hostname/password in its *app* databag.
"""

import logging
import os

import jinja2
import ops

logger = logging.getLogger(__name__)

TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")
CONTAINER = "trilio-dms"
SERVER_CONF = "/etc/triliovault-dms/server.conf"
CLIENT_CONF = "/etc/triliovault-dms/client.conf"
DMS_CLIENT_LOG_FILE = "/var/log/triliovault/trilio-dms-client.log"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
OBJECT_STORE_LOGGING_CONF_PATH = "/etc/triliovault-object-store/object_store_logging.conf"
LOG_FILE = "/var/log/triliovault/trilio-dms-server.log"



class TrilioDmsK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_dms_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._configure)
        self.framework.observe(self.on.amqp_relation_changed, self._configure)
        self.framework.observe(self.on.amqp_relation_joined, self._on_amqp_relation_joined)
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._configure
        )

    def _on_pebble_ready(self, event):
        self._configure(event)

    def _on_amqp_relation_joined(self, event):
        """Write rabbitmq requirer credentials to app databag so rabbitmq-k8s provisions them.

        DMS uses the same vhost as DMAPI since they communicate via shared RabbitMQ queues.
        """
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "dmapi"
            event.relation.data[self.app]["vhost"] = "dmapi"

    def _send_relation_requests(self):
        """Idempotently write relation requests in case joined events were missed."""
        if not self.unit.is_leader():
            return
        amqp_rel = self.model.get_relation("amqp")
        if amqp_rel and not amqp_rel.data[self.app].get("username"):
            amqp_rel.data[self.app]["username"] = "dmapi"
            amqp_rel.data[self.app]["vhost"] = "dmapi"

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
        self._write_client_config(container)
        self._write_s3vaultfuse_config(container)
        self._write_ca_cert(container)
        self._update_pebble_layer(container)
        self.unit.status = ops.ActiveStatus("DMS server running")

    def _missing_relations(self):
        missing = []
        if not self._amqp_data():
            missing.append("amqp")
        return missing

    def _amqp_data(self):
        """rabbitmq interface: provider writes hostname/password into its app databag."""
        rel = self.model.get_relation("amqp")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        host = d.get("hostname") or d.get("host")
        if host and d.get("password"):
            return {**dict(d), "host": host}
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

    def _get_node_name(self, container):
        """Get k8s node hostname via Downward API K8S_NODE_NAME injected into workload container."""
        try:
            out, _ = container.exec(["printenv", "K8S_NODE_NAME"]).wait_output()
            node_name = out.strip()
            if node_name:
                return node_name
        except Exception as e:
            logger.warning("Failed to read K8S_NODE_NAME: %s", e)
        logger.warning("K8S_NODE_NAME not available, falling back to unit name")
        return self.unit.name.replace("/", "-")

    def _render_template(self, template_name: str, context: dict) -> str:
        """Render a Jinja2 template from src/templates/."""
        loader = jinja2.FileSystemLoader(TEMPLATE_DIR)
        env = jinja2.Environment(loader=loader, keep_trailing_newline=True)
        return env.get_template(template_name).render(**context)

    def _write_config(self, container):
        amqp = self._amqp_data()
        transport_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
        )
        cafile = "/usr/local/share/ca-certificates/ca-bundle.pem" if self._get_ca_cert() else ""
        context = {
            "rabbitmq_url": transport_url,
            "node_id": self._get_node_name(container),
            "auth_url": self.config["keystone-endpoint"],
            "barbican_ssl_verify": "False" if not self._get_ca_cert() else "True",
            "cafile": cafile,
            "log_file": LOG_FILE,
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "worker_threads": self.config["worker-threads"],
        }
        rendered = self._render_template("triliovault-dms-server.conf.j2", context)
        container.push(SERVER_CONF, rendered, make_dirs=True)
        logger.info("Wrote %s", SERVER_CONF)

    def _write_client_config(self, container):
        """Write /etc/triliovault-dms/client.conf (DMS client side — mirrors kolla client template)."""
        amqp = self._amqp_data()
        transport_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
        )
        context = {
            "rabbitmq_url": transport_url,
            "node_id": self._get_node_name(container),
            "db_url": self.config.get("wlm-db-url", ""),
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "log_file": DMS_CLIENT_LOG_FILE,
        }
        rendered = self._render_template("triliovault-dms-client.conf.j2", context)
        container.push(CLIENT_CONF, rendered, make_dirs=True)
        logger.info("Wrote %s", CLIENT_CONF)

    def _write_s3vaultfuse_config(self, container):
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
