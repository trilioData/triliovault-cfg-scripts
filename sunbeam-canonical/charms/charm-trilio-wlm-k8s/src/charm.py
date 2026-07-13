#!/usr/bin/env python3
"""TrilioVault WorkloadManager Kubernetes charm for Sunbeam Canonical OpenStack.

Manages four WLM microservices via Pebble inside a single k8s pod:
  wlm-api, wlm-workloads, wlm-scheduler, wlm-cron (leader-only singleton).
"""

import configparser
import io
import logging

import ops

logger = logging.getLogger(__name__)

CONTAINER = "trilio-wlm"
CONFIG_PATH = "/etc/workloadmgr/workloadmgr.conf"
LOG_DIR = "/var/log/workloadmgr"
WLM_PORT = 8781


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

        if self.unit.is_leader():
            self._publish_wlm_service_data()

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
        rel = self.model.get_relation("database")
        if not rel:
            return None
        for unit in rel.units:
            d = rel.data[unit]
            if d.get("host") and d.get("password"):
                return d
        return None

    def _amqp_data(self):
        rel = self.model.get_relation("amqp")
        if not rel:
            return None
        for unit in rel.units:
            d = rel.data[unit]
            if d.get("host") and d.get("password"):
                return d
        return None

    def _identity_data(self):
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

        transport_url = (
            f"rabbit://{amqp.get('username', 'wlm')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'wlm')}"
        )
        db_url = (
            f"mysql+pymysql://{db.get('username', 'wlm')}:{db['password']}"
            f"@{db['host']}/{db.get('database', 'workloadmgr')}"
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
        }
        cfg["database"] = {
            "connection": db_url,
        }
        cfg["keystone_authtoken"] = {
            "auth_url": auth_url,
            "username": identity.get("service_username", "wlm"),
            "password": identity["service_password"],
            "project_name": identity.get("service_tenant", "services"),
            "user_domain_name": "Default",
            "project_domain_name": "Default",
            "auth_type": "password",
        }
        cfg["wlm"] = {
            "api_workers": str(self.config["api-workers"]),
        }

        self._add_backup_target_config(cfg)

        buf = io.StringIO()
        cfg.write(buf)
        container.push(CONFIG_PATH, buf.getvalue(), make_dirs=True)
        logger.info("Wrote %s", CONFIG_PATH)

    def _add_backup_target_config(self, cfg):
        target_type = self.config["backup-target-type"]
        if target_type == "nfs":
            cfg["nfs"] = {
                "shares": self.config["nfs-shares"],
                "options": self.config["nfs-options"],
            }
        elif target_type == "s3":
            cfg["s3"] = {
                "access_key": self.config["s3-access-key"],
                "secret_key": self.config["s3-secret-key"],
                "bucket": self.config["s3-bucket"],
                "region_name": self.config["s3-region"],
                "endpoint_url": self.config["s3-endpoint-url"],
                "ssl_enabled": str(self.config["s3-ssl-enabled"]).lower(),
            }

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
        # wlm-cron must run as a single instance cluster-wide — restrict to leader unit.
        # Multiple wlm-cron instances cause duplicate scheduled job execution
        # and corrupt workload state in the database.
        if self.unit.is_leader():
            services["wlm-cron"] = {
                "override": "replace",
                "summary": "WLM Cron (leader-only singleton)",
                "command": cmd_base.format("wlm-cron"),
                "startup": "enabled",
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


if __name__ == "__main__":
    ops.main(TrilioWlmK8sCharm)
