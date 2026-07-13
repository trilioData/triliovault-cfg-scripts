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
import socket

import ops

logger = logging.getLogger(__name__)

CONTAINER = "trilio-dms"
SERVER_CONF = "/etc/triliovault-dms/server.conf"
LOG_FILE = "/var/log/triliovault/trilio-dms-server.log"


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

    def _on_pebble_ready(self, event):
        self._configure(event)

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
            if d.get("service_host"):
                return d
        return None

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
            "node_id": socket.gethostname(),
            "log_file": LOG_FILE,
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "s3vaultfuse_bin": "/usr/bin/s3vaultfuse.py",
            "rootwrap_bin": "/usr/bin/trilio-dms-rootwrap",
            "rootwrap_conf": "/etc/triliovault-dms/rootwrap.conf",
            "worker_threads": str(self.config["worker-threads"]),
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(SERVER_CONF, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", SERVER_CONF)

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
                }
            },
        })
        container.add_layer(CONTAINER, layer, combine=True)
        container.replan()
        logger.info("Pebble layer applied for trilio-dms-server")


if __name__ == "__main__":
    ops.main(TrilioDmsK8sCharm)
