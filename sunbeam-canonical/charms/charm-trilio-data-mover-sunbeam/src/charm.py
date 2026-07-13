#!/usr/bin/env python3
"""TrilioVault DataMover subordinate charm for Sunbeam Canonical OpenStack.

Installs tvault-contego on every openstack-hypervisor compute node.
Automatically co-located via juju-info subordinate relation — no manual
action needed when a new compute node joins the cluster.
"""

import configparser
import io
import logging
import os
import subprocess

import ops

logger = logging.getLogger(__name__)

SERVICE = "tvault-contego"
CONFIG_PATH = "/etc/tvault-contego/tvault-contego.conf"
TRILIO_GPG_URL = "https://apt.trilio.io/key.gpg"
TRILIO_GPG_PATH = "/etc/apt/trusted.gpg.d/trilio.gpg"
TRILIO_LIST_PATH = "/etc/apt/sources.list.d/trilio.list"


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

    # --- event handlers ---

    def _on_install(self, event):
        self.unit.status = ops.MaintenanceStatus("Installing tvault-contego")
        try:
            self._setup_apt_repo()
            self._install_package()
        except subprocess.CalledProcessError as e:
            logger.error("Package install failed: %s", e)
            self.unit.status = ops.BlockedStatus(f"Package install failed: {e}")
            return
        self.unit.status = ops.WaitingStatus("Waiting for amqp and identity-credentials")

    def _on_config_changed(self, event):
        self._configure(event)

    def _on_upgrade_charm(self, event):
        self.unit.status = ops.MaintenanceStatus("Upgrading tvault-contego")
        try:
            self._install_package()
        except subprocess.CalledProcessError as e:
            self.unit.status = ops.BlockedStatus(f"Upgrade failed: {e}")
            return
        self._configure(event)

    def _on_relation_changed(self, event):
        self._configure(event)

    def _on_juju_info_joined(self, event):
        # Principal (openstack-hypervisor) unit attached — attempt configuration
        self._configure(event)

    # --- core configure logic ---

    def _configure(self, event):
        missing = self._missing_relations()
        if missing:
            self.unit.status = ops.WaitingStatus(f"Waiting for: {', '.join(missing)}")
            return

        try:
            self._write_config()
            self._restart_service()
        except Exception as e:
            logger.error("Configuration failed: %s", e)
            self.unit.status = ops.BlockedStatus(f"Configuration error: {e}")
            return

        self.unit.status = ops.ActiveStatus("DataMover running")

    def _missing_relations(self):
        missing = []
        if not self._amqp_data():
            missing.append("amqp")
        if not self._identity_data():
            missing.append("identity-credentials")
        return missing

    # --- relation data helpers ---

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
        rel = self.model.get_relation("identity-credentials")
        if not rel:
            return None
        for unit in rel.units:
            d = rel.data[unit]
            if d.get("credentials_host") and d.get("credentials_password"):
                return d
        return None

    # --- apt repo and package installation ---

    def _setup_apt_repo(self):
        pkg_source = self.config["triliovault-pkg-source"]
        subprocess.run(
            ["bash", "-c",
             f"curl -fsSL {TRILIO_GPG_URL} | gpg --dearmor -o {TRILIO_GPG_PATH}"],
            check=True,
        )
        with open(TRILIO_LIST_PATH, "w") as f:
            f.write(f"{pkg_source}\n")
        subprocess.run(["apt-get", "update", "-qq"], check=True)
        logger.info("Trilio apt repo configured")

    def _install_package(self):
        version = self.config["trilio-version"].strip()
        pkg = f"{SERVICE}={version}*" if version else SERVICE
        subprocess.run(
            ["apt-get", "install", "-y", "--no-install-recommends", pkg],
            check=True,
        )
        logger.info("Installed %s", pkg)

    # --- config file rendering ---

    def _write_config(self):
        amqp = self._amqp_data()
        identity = self._identity_data()

        transport_url = (
            f"rabbit://{amqp.get('username', 'datamover')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'datamover')}"
        )
        auth_url = (
            f"{identity.get('credentials_protocol', 'http')}://"
            f"{identity['credentials_host']}:{identity.get('credentials_port', '5000')}/v3"
        )

        cfg = configparser.ConfigParser()

        cfg["DEFAULT"] = {
            "transport_url": transport_url,
            "auth_strategy": "keystone",
            "debug": str(self.config["debug"]).lower(),
        }
        cfg["keystone_authtoken"] = {
            "auth_url": auth_url,
            "username": identity.get("credentials_username", "datamover"),
            "password": identity["credentials_password"],
            "project_name": identity.get("credentials_project", "services"),
            "user_domain_name": "Default",
            "project_domain_name": "Default",
            "auth_type": "password",
        }

        self._add_backup_target_config(cfg)

        buf = io.StringIO()
        cfg.write(buf)

        os.makedirs("/etc/tvault-contego", exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            f.write(buf.getvalue())
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

    # --- service management ---

    def _restart_service(self):
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", SERVICE], check=True)
        subprocess.run(["systemctl", "restart", SERVICE], check=True)
        logger.info("Restarted %s", SERVICE)


if __name__ == "__main__":
    ops.main(TrilioDataMoverSunbeamCharm)
