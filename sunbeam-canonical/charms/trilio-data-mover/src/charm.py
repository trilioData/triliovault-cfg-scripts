#!/usr/bin/env python3
"""TrilioVault DataMover subordinate charm for Sunbeam Canonical OpenStack.

Installs tvault-contego AND the compute-side trilio-dms-server on every
openstack-hypervisor compute node.

Automatically co-located via juju-info subordinate relation — no manual
action needed when a new compute node joins the cluster via sunbeam cluster join.

DMS note: A DMS server must run on both control plane (trilio-dms-k8s)
and every compute node (this charm). The two instances communicate via RabbitMQ
and handle NFS / S3 mount operations on their respective hosts.
"""

import configparser
import io
import logging
import os
import socket
import subprocess

import ops

logger = logging.getLogger(__name__)

DATAMOVER_SERVICE = "tvault-contego"
DMS_SERVICE = "triliovault-dms"
DM_CONFIG_PATH = "/etc/tvault-contego/tvault-contego.conf"
DMS_CONFIG_PATH = "/etc/triliovault-dms/server.conf"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
DMS_LOG_FILE = "/var/log/triliovault/trilio-dms-server.log"
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
        self.unit.status = ops.MaintenanceStatus("Installing TrilioVault packages")
        try:
            self._setup_apt_repo()
            self._install_packages()
            self._create_directories()
        except subprocess.CalledProcessError as e:
            logger.error("Package install failed: %s", e)
            self.unit.status = ops.BlockedStatus(f"Package install failed: {e}")
            return
        self.unit.status = ops.WaitingStatus("Waiting for amqp and identity-credentials")

    def _on_config_changed(self, event):
        self._configure(event)

    def _on_upgrade_charm(self, event):
        self.unit.status = ops.MaintenanceStatus("Upgrading TrilioVault packages")
        try:
            self._install_packages()
        except subprocess.CalledProcessError as e:
            self.unit.status = ops.BlockedStatus(f"Upgrade failed: {e}")
            return
        self._configure(event)

    def _on_relation_changed(self, event):
        self._configure(event)

    def _on_juju_info_joined(self, event):
        self._configure(event)

    # --- core configure logic ---

    def _configure(self, event):
        missing = self._missing_relations()
        if missing:
            self.unit.status = ops.WaitingStatus(f"Waiting for: {', '.join(missing)}")
            return

        try:
            self._write_datamover_config()
            self._write_dms_config()
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
        """rabbitmq interface: unit databag. Accept hostname or host."""
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
        """keystone-credentials interface: unit databag."""
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

    def _install_packages(self):
        version = self.config["trilio-version"].strip()

        # tvault-contego: datamover service package
        dm_pkg = f"{DATAMOVER_SERVICE}={version}*" if version else DATAMOVER_SERVICE
        # python3-trilio-dms: DMS server package (compute-side instance)
        dms_pkg = f"python3-trilio-dms={version}*" if version else "python3-trilio-dms"

        subprocess.run(
            ["apt-get", "install", "-y", "--no-install-recommends",
             "fuse", "libfuse2", "nfs-common", "python3-s3-fuse-plugin",
             dm_pkg, dms_pkg],
            check=True,
        )
        logger.info("Installed %s and python3-trilio-dms", dm_pkg)

    def _create_directories(self):
        dirs = [
            "/etc/tvault-contego",
            "/etc/triliovault-dms",
            "/var/log/triliovault",
            "/var/lib/trilio/triliovault-mounts",
            "/var/triliovault",
            "/run/dms",
            "/run/dms/s3",
        ]
        for d in dirs:
            os.makedirs(d, exist_ok=True)
        # Fuse requires user_allow_other for DMS FUSE mounts
        with open("/etc/fuse.conf", "a") as f:
            f.write("\nuser_allow_other\n")
        logger.info("Directories created")

    # --- datamover config file rendering ---

    def _write_datamover_config(self):
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
        buf = io.StringIO()
        cfg.write(buf)
        os.makedirs("/etc/tvault-contego", exist_ok=True)
        with open(DM_CONFIG_PATH, "w") as f:
            f.write(buf.getvalue())
        logger.info("Wrote %s", DM_CONFIG_PATH)

    # --- DMS config file rendering ---

    def _write_dms_config(self):
        amqp = self._amqp_data()
        identity = self._identity_data()

        transport_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
        )
        auth_url = (
            f"{identity.get('credentials_protocol', 'http')}://"
            f"{identity['credentials_host']}:{identity.get('credentials_port', '5000')}/v3"
        )

        cfg = configparser.ConfigParser()
        cfg["server"] = {
            "rabbitmq_url": transport_url,
            "auth_url": auth_url,
            "node_id": socket.gethostname(),
            "log_file": DMS_LOG_FILE,
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "s3vaultfuse_bin": "/usr/bin/s3vaultfuse.py",
            "rootwrap_bin": "/usr/bin/trilio-dms-rootwrap",
            "rootwrap_conf": "/etc/triliovault-dms/rootwrap.conf",
            "worker_threads": "10",
        }

        buf = io.StringIO()
        cfg.write(buf)
        os.makedirs("/etc/triliovault-dms", exist_ok=True)
        with open(DMS_CONFIG_PATH, "w") as f:
            f.write(buf.getvalue())
        logger.info("Wrote %s", DMS_CONFIG_PATH)

    def _write_s3vaultfuse_config(self):
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
        os.makedirs("/etc/triliovault-dms", exist_ok=True)
        with open(S3VAULTFUSE_CONF, "w") as f:
            f.write(content)
        logger.info("Wrote %s", S3VAULTFUSE_CONF)

    # --- service management ---

    def _restart_services(self):
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        for svc in (DATAMOVER_SERVICE, DMS_SERVICE):
            subprocess.run(["systemctl", "enable", svc], check=True)
            subprocess.run(["systemctl", "restart", svc], check=True)
            logger.info("Restarted %s", svc)


if __name__ == "__main__":
    ops.main(TrilioDataMoverSunbeamCharm)
