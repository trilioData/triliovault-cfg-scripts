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
CONFIG_PATH = "/etc/triliovault-datamover/dmapi.conf"
LOG_DIR = "/var/log/triliovault-datamover"
DMAPI_PORT = 8784


class TrilioDmApiK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_dm_api_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._configure)
        for rel in ("database", "amqp", "identity_service", "wlm_service"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_changed"), self._configure
            )

    # --- event handlers ---

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
        """wlm-service: trilio-wlm-k8s writes wlm-api-url into its app databag."""
        rel = self.model.get_relation("wlm-service")
        if not rel:
            return None
        for app in rel.apps:
            if app is self.app:
                continue
            d = rel.data[app]
            if d.get("wlm-api-url"):
                return d
        return None

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
            "debug": str(self.config["debug"]).lower(),
            "wlm_endpoint": wlm["wlm-api-url"],
        }
        cfg["database"] = {
            "connection": db_url,
        }
        cfg["keystone_authtoken"] = {
            "auth_url": auth_url,
            "username": identity.get("service_username", "dmapi"),
            "password": identity["service_password"],
            "project_name": identity.get("service_tenant", "services"),
            "user_domain_name": "Default",
            "project_domain_name": "Default",
            "auth_type": "password",
        }
        cfg["dmapi"] = {
            "api_workers": str(self.config["api-workers"]),
        }

        buf = io.StringIO()
        cfg.write(buf)
        container.push(CONFIG_PATH, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", CONFIG_PATH)

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
                }
            },
        })
        container.add_layer(CONTAINER, layer, combine=True)
        container.replan()
        logger.info("Pebble layer applied for dmapi-api")


if __name__ == "__main__":
    ops.main(TrilioDmApiK8sCharm)
