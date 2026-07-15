#!/usr/bin/env python3
# Ensure charm venv is on sys.path regardless of how the dispatch script is generated.
import sys as _sys, pathlib as _pathlib
_venv = _pathlib.Path(__file__).parent.parent / "venv"
if str(_venv) not in _sys.path:
    _sys.path.insert(0, str(_venv))
del _sys, _pathlib

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
import pathlib
import shutil
import socket
import subprocess

import ops

logger = logging.getLogger(__name__)

DATAMOVER_PACKAGE = "python3-tvault-contego"
DATAMOVER_SERVICE = "triliovault-datamover"
DMS_SERVICE = "triliovault-dms"
DM_CONFIG_PATH = "/etc/triliovault-datamover/triliovault-datamover.conf"
DM_LOGGING_CONF_PATH = "/etc/triliovault-datamover/datamover_logging.conf"
DMS_CONFIG_PATH = "/etc/triliovault-dms/server.conf"
DMS_CLIENT_CONF_PATH = "/etc/triliovault-dms/client.conf"
S3VAULTFUSE_CONF = "/etc/triliovault-dms/s3vaultfuse-global.conf"
OBJECT_STORE_LOGGING_CONF_PATH = "/etc/triliovault-object-store/object_store_logging.conf"
DMS_LOG_FILE = "/var/log/triliovault/trilio-dms-server.log"
DMS_CLIENT_LOG_FILE = "/var/log/triliovault/trilio-dms-client.log"
TRILIO_LIST_PATH = "/etc/apt/sources.list.d/trilio.list"

# Systemd unit for the DMS server on compute nodes.
# python3-trilio-dms is designed for kolla (container); it ships no systemd unit.
DMS_SYSTEMD_UNIT = """\
[Unit]
Description=TrilioVault Dynamic Mount Service
After=network.target

[Service]
User=nova
Group=nova
Type=simple
ExecStart=/usr/bin/python3 /usr/bin/trilio-dms-server --config-file /etc/triliovault-dms/server.conf
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""

# Systemd unit for tvault-contego on Sunbeam compute nodes.
# Nova config lives inside the openstack-hypervisor snap, not /etc/nova/nova.conf.
DATAMOVER_SYSTEMD_UNIT = """\
[Unit]
Description=TrilioVault DataMover (tvault-contego)
After=network.target
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
User=nova
Group=nova
Type=simple
ExecStart=/usr/bin/python3 /usr/bin/tvault-contego \
  --config-file=/var/snap/openstack-hypervisor/common/etc/nova/nova.conf \
  --config-file=/etc/triliovault-datamover/triliovault-datamover.conf
TimeoutStopSec=20
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""

# Python logging config referenced by datamover (tvault-contego) via log_config_append.
# Content matches the RHOSO18 / kolla-ansible reference. Without this file the
# tvault-contego binary fails to start (oslo.log aborts on a missing log_config_append).
DATAMOVER_LOGGING_CONF = """\
[loggers]
keys = root,contego

[handlers]
keys = datamover,stdout,stderr,null

[formatters]
keys = default,advanced,default-utc,advanced-utc

[logger_root]
level = INFO
handlers = stdout

[logger_contego]
level = INFO
handlers = datamover,stdout,stderr
qualname = contego

[handler_datamover]
class = logging.handlers.RotatingFileHandler
args = ('/var/log/triliovault/triliovault-datamover.log','a',25000000,20)
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
class = contego.common.log.UTCFormatter
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced-utc]
class = contego.common.log.UTCFormatter
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_default]
format = %(asctime)s - %(name)s - %(levelname)s - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z

[formatter_advanced]
format =  %(asctime)s - %(name)s - %(levelname)s - PID:%(process)d - TID:%(thread)d - %(message)s
datefmt = %Y-%m-%d %H:%M:%S,%s %Z
"""

# Python logging config referenced by s3vaultfuse via log_config_append.
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
        self.framework.observe(self.on.amqp_relation_joined, self._on_amqp_relation_joined)
        self.framework.observe(
            self.on.identity_credentials_relation_joined,
            self._on_identity_credentials_relation_joined,
        )
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._on_relation_changed
        )

    # --- event handlers ---

    def _on_install(self, event):
        self.unit.status = ops.MaintenanceStatus("Installing TrilioVault packages")
        try:
            self._setup_apt_repo()
            self._install_packages()
            self._create_directories()
            self._write_nova_sudoers()
            self._install_rootwrap_filters()
            self._write_systemd_services()
        except subprocess.CalledProcessError as e:
            logger.error("Package install failed: %s", e)
            self.unit.status = ops.BlockedStatus(f"Package install failed: {e}")
            return
        self.unit.status = ops.WaitingStatus("Waiting for amqp and identity-credentials relations")

    def _on_config_changed(self, event):
        self._configure(event)

    def _on_upgrade_charm(self, event):
        self.unit.status = ops.MaintenanceStatus("Upgrading TrilioVault packages")
        try:
            # Re-run apt repo setup on upgrade — the repo URL may have changed between
            # Trilio releases and must be refreshed before installing the new package.
            self._setup_apt_repo()
            self._install_packages()
        except subprocess.CalledProcessError as e:
            self.unit.status = ops.BlockedStatus(f"Upgrade failed: {e}")
            return
        # Re-send relation requests in case the relations were joined before this charm
        # version had the correct app-bag write logic. Idempotent.
        self._send_relation_requests()
        self._configure(event)

    def _on_relation_changed(self, event):
        self._configure(event)

    def _on_juju_info_joined(self, event):
        self._configure(event)

    def _on_amqp_relation_joined(self, event):
        """Write rabbitmq requirer credentials so rabbitmq-k8s provisions the user/vhost."""
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "datamover"
            event.relation.data[self.app]["vhost"] = "datamover"

    def _on_identity_credentials_relation_joined(self, event):
        """Write keystone requirer username so keystone-k8s provisions datamover credentials."""
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "datamover"

    def _send_relation_requests(self):
        """Idempotently write requirer bags for amqp and identity-credentials.

        Called on upgrade-charm to handle the case where these relations were
        already joined before the charm had this write logic in place.
        """
        if not self.unit.is_leader():
            return
        amqp_rel = self.model.get_relation("amqp")
        if amqp_rel:
            amqp_rel.data[self.app]["username"] = "datamover"
            amqp_rel.data[self.app]["vhost"] = "datamover"
        identity_rel = self.model.get_relation("identity-credentials")
        if identity_rel:
            identity_rel.data[self.app]["username"] = "datamover"

    # --- core configure logic ---

    def _configure(self, event):
        missing = self._missing_relations()
        if missing:
            self.unit.status = ops.WaitingStatus(f"Waiting for: {', '.join(missing)}")
            return

        try:
            self._write_datamover_config()
            self._write_dms_config()
            self._write_dms_client_config()
            self._write_s3vaultfuse_config()
            self._write_ca_cert()
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
        """rabbitmq interface: provider app databag. Accept hostname or host."""
        rel = self.model.get_relation("amqp")
        if not rel:
            return None
        d = rel.data[rel.app]
        host = d.get("hostname") or d.get("host")
        if host and d.get("password"):
            return {**dict(d), "host": host}
        return None

    def _identity_data(self):
        """keystone-credentials interface: provider app databag.

        The keystone-credentials interface returns auth-host, auth-port,
        auth-protocol, and a Juju secret under 'credentials' that holds
        the actual username/password. Returns a normalized dict with
        credentials_host, credentials_password, etc. so callers don't
        need to know the wire format.
        """
        rel = self.model.get_relation("identity-credentials")
        if not rel:
            return None
        d = rel.data[rel.app]
        host = d.get("auth-host")
        secret_id = d.get("credentials")
        if not host or not secret_id:
            return None
        try:
            secret = self.model.get_secret(id=secret_id)
            creds = secret.get_content()
        except Exception:
            return None
        if not creds.get("password"):
            return None
        return {
            "credentials_host": host,
            "credentials_port": d.get("auth-port", "5000"),
            "credentials_protocol": d.get("auth-protocol", "http"),
            "credentials_username": creds.get("username", "datamover"),
            "credentials_password": creds["password"],
            "credentials_project": d.get("project-name", "services"),
            "internal_endpoint": d.get("internal-endpoint", ""),
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

    def _write_ca_cert(self):
        """Write CA bundle to the host system for tvault-contego Keystone TLS verification."""
        ca_cert = self._get_ca_cert()
        if not ca_cert:
            return
        ca_path = "/usr/local/share/ca-certificates/trilio-ca.crt"
        os.makedirs(os.path.dirname(ca_path), exist_ok=True)
        with open(ca_path, "w") as f:
            f.write(ca_cert)
        subprocess.run(["update-ca-certificates"], check=True)
        logger.info("CA cert written to %s", ca_path)

    # --- apt repo and package installation ---

    def _setup_apt_repo(self):
        pkg_source = self.config["triliovault-pkg-source"]
        with open(TRILIO_LIST_PATH, "w") as f:
            f.write(f"{pkg_source}\n")
        subprocess.run(["apt-get", "update", "-qq"], check=True)
        logger.info("Trilio apt repo configured")

    def _ensure_nova_user(self):
        """Create nova system user/group if absent, then add to disk and kvm groups.

        python3-tvault-contego postinst runs usermod for nova. On Sunbeam compute
        nodes nova-compute runs inside the openstack-hypervisor snap and no host-level
        nova user is created by the snap, so the postinst fails without this.
        nova needs disk+kvm group membership for libvirt/QEMU operations (mirrors
        the kolla Dockerfile: usermod -aG disk,kvm nova).
        """
        try:
            subprocess.run(["getent", "passwd", "nova"], check=True,
                           capture_output=True)
        except subprocess.CalledProcessError:
            subprocess.run(["addgroup", "--system", "nova"], check=False)
            subprocess.run(
                ["adduser", "--system", "--no-create-home",
                 "--ingroup", "nova", "nova"],
                check=True,
            )
            logger.info("Created system user nova")
        for grp in ("disk", "kvm"):
            subprocess.run(["usermod", "-aG", grp, "nova"], check=False)

    def _install_packages(self):
        version = self.config["trilio-version"].strip()

        dm_pkg = f"{DATAMOVER_PACKAGE}={version}*" if version else DATAMOVER_PACKAGE
        dms_pkg = f"python3-trilio-dms={version}*" if version else "python3-trilio-dms"

        self._ensure_nova_user()
        subprocess.run(
            ["apt-get", "install", "-y", "--no-install-recommends",
             "fuse", "libfuse2", "nfs-common",
             "udev", "qemu-utils", "ceph-common",
             "python3-novaclient", "python3-cinderclient",
             "python3-libvirt", "python3-s3-fuse-plugin",
             dm_pkg, dms_pkg],
            check=True,
        )
        logger.info("Installed %s and python3-trilio-dms", dm_pkg)

    def _create_directories(self):
        dirs = [
            "/etc/triliovault-datamover",
            "/etc/triliovault-dms",
            "/etc/triliovault-object-store",
            "/var/log/triliovault",
            "/var/triliovault-mounts",
            "/var/triliovault",
            "/opt/triliovault",
            "/run/dms",
            "/run/dms/s3",
        ]
        for d in dirs:
            os.makedirs(d, exist_ok=True)
        # opt/triliovault owned by nova (mirrors kolla Dockerfile)
        shutil.chown("/opt/triliovault", user="nova", group="nova")
        shutil.chown("/var/triliovault-mounts", user="nova", group="nova")
        shutil.chown("/var/triliovault", user="nova", group="nova")
        os.chmod("/var/triliovault-mounts", 0o777)
        os.chmod("/var/triliovault", 0o777)
        # Fuse requires user_allow_other for DMS FUSE mounts.
        # Guard before appending — this method is called on install AND on
        # config-changed, so naively appending would duplicate the line on every
        # re-configuration, eventually corrupting the file.
        fuse_conf = "/etc/fuse.conf"
        with open(fuse_conf, "r") as f:
            fuse_content = f.read()
        if "user_allow_other" not in fuse_content:
            with open(fuse_conf, "a") as f:
                f.write("\nuser_allow_other\n")
        logger.info("Directories created")

    # --- datamover config file rendering ---

    def _write_datamover_config(self):
        amqp = self._amqp_data()

        transport_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
        )

        cfg = configparser.ConfigParser()
        cfg["DEFAULT"] = {
            "dmapi_transport_url": transport_url,
            "vault_data_directory": "/var/triliovault-mounts",
            "vault_data_directory_old": "/var/triliovault",
            "qemu_agent_ping_timeout": "30",
            "log_config_append": "/etc/triliovault-datamover/datamover_logging.conf",
            "max_uploads_pending": "3",
            "max_commit_pending": "3",
            "debug": str(self.config["debug"]).lower(),
        }
        cfg["contego_sys_admin"] = {
            # Must use tvault-contego-rootwrap so privileged disk/mount operations
            # are executed through the rootwrap filter. Bare privsep-helper without
            # rootwrap bypasses the allow-list and causes permission errors.
            "helper_command": (
                "sudo /usr/bin/tvault-contego-rootwrap"
                f" {DM_CONFIG_PATH} privsep-helper"
            ),
        }
        cfg["conductor"] = {
            "use_local": "True",
        }
        cfg["s3fuse_sys_admin"] = {
            # DMS uses its own rootwrap binary for s3/fuse privilege escalation.
            "helper_command": (
                "sudo /usr/bin/trilio-dms-rootwrap"
                " /etc/triliovault-dms/rootwrap.conf privsep-helper"
            ),
        }
        buf = io.StringIO()
        cfg.write(buf)
        os.makedirs("/etc/triliovault-datamover", exist_ok=True)
        with open(DM_CONFIG_PATH, "w") as f:
            f.write(buf.getvalue())
        logger.info("Wrote %s", DM_CONFIG_PATH)
        with open(DM_LOGGING_CONF_PATH, "w") as f:
            f.write(DATAMOVER_LOGGING_CONF)
        logger.info("Wrote %s", DM_LOGGING_CONF_PATH)

    # --- DMS config file rendering ---

    def _write_dms_config(self):
        amqp = self._amqp_data()
        identity = self._identity_data()

        transport_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
        )
        # Use the HTTPS internal endpoint if keystone published one via traefik;
        # fall back to plain-http k8s service address for fresh deploys.
        auth_url = (
            identity.get("internal_endpoint")
            or (
                f"{identity.get('credentials_protocol', 'http')}://"
                f"{identity['credentials_host']}:{identity.get('credentials_port', '5000')}/v3"
            )
        )

        cfg = configparser.ConfigParser()
        cfg["server"] = {
            "rabbitmq_url": transport_url,
            "auth_url": auth_url,
            "node_id": socket.getfqdn(),
            "log_file": DMS_LOG_FILE,
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "log_max_bytes": "26214400",
            "log_backup_count": "5",
            "s3vaultfuse_bin": "/usr/bin/s3vaultfuse.py",
            "rootwrap_bin": "/usr/bin/trilio-dms-rootwrap",
            "rootwrap_conf": "/etc/triliovault-dms/rootwrap.conf",
            "worker_threads": "10",
            "barbican_ssl_verify": "True",
        }

        buf = io.StringIO()
        cfg.write(buf)
        os.makedirs("/etc/triliovault-dms", exist_ok=True)
        with open(DMS_CONFIG_PATH, "w") as f:
            f.write(buf.getvalue())
        logger.info("Wrote %s", DMS_CONFIG_PATH)

    def _write_dms_client_config(self):
        """Write /etc/triliovault-dms/client.conf for tvault-contego DMS client.

        db_url must point to WLM database — set wlm-db-url charm config.
        Skipped with a warning if wlm-db-url is not configured.
        """
        wlm_db_url = self.config.get("wlm-db-url", "").strip()
        if not wlm_db_url:
            logger.warning("wlm-db-url not set — skipping DMS client.conf")
            return

        amqp = self._amqp_data()
        transport_url = (
            f"rabbit://{amqp.get('username', 'dmapi')}:{amqp['password']}"
            f"@{amqp['host']}:{amqp.get('port', '5672')}"
            f"/{amqp.get('vhost', 'dmapi')}"
        )

        cfg = configparser.ConfigParser()
        cfg["client"] = {
            "rabbitmq_url": transport_url,
            "db_url": wlm_db_url,
            "node_id": socket.getfqdn(),
            "request_timeout": "60",
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "log_file": DMS_CLIENT_LOG_FILE,
            "log_max_bytes": "26214400",
            "log_backup_count": "5",
            "db_pool_size": "20",
            "db_max_overflow": "40",
            "db_pool_recycle": "3600",
        }

        buf = io.StringIO()
        cfg.write(buf)
        os.makedirs("/etc/triliovault-dms", exist_ok=True)
        with open(DMS_CLIENT_CONF_PATH, "w") as f:
            f.write(buf.getvalue())
        logger.info("Wrote %s", DMS_CLIENT_CONF_PATH)

    def _write_nova_sudoers(self):
        """Write sudoers rule for nova privsep-helper (mirrors kolla nova-sudoers)."""
        sudoers_path = "/etc/sudoers.d/nova-sudoers"
        content = "nova ALL=(root) NOPASSWD: /usr/bin/privsep-helper *\n"
        os.makedirs("/etc/sudoers.d", exist_ok=True)
        with open(sudoers_path, "w") as f:
            f.write(content)
        os.chmod(sudoers_path, 0o440)
        logger.info("Wrote %s", sudoers_path)

    def _install_rootwrap_filters(self):
        """Install trilio.filters for nova rootwrap (mirrors kolla ADD trilio.filters)."""
        filters_dir = "/usr/share/nova/rootwrap"
        filters_src = pathlib.Path(__file__).parent.parent / "files" / "trilio.filters"
        if filters_src.exists():
            os.makedirs(filters_dir, exist_ok=True)
            shutil.copy2(str(filters_src), os.path.join(filters_dir, "trilio.filters"))
            logger.info("Installed trilio.filters to %s", filters_dir)
        else:
            logger.warning("trilio.filters not found in charm files/, skipping rootwrap install")

    def _write_systemd_services(self):
        """Write systemd unit files for DMS server and tvault-contego.

        Both units are not shipped by their packages (designed for kolla containers).
        Written once at install time; daemon-reload is called before service start.
        """
        units = {
            f"/lib/systemd/system/{DMS_SERVICE}.service": DMS_SYSTEMD_UNIT,
            f"/lib/systemd/system/{DATAMOVER_SERVICE}.service": DATAMOVER_SYSTEMD_UNIT,
        }
        for path, content in units.items():
            with open(path, "w") as f:
                f.write(content)
            logger.info("Wrote systemd unit %s", path)

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
        os.makedirs("/etc/triliovault-dms", exist_ok=True)
        with open(S3VAULTFUSE_CONF, "w") as f:
            f.write(content)
        logger.info("Wrote %s", S3VAULTFUSE_CONF)
        os.makedirs("/etc/triliovault-object-store", exist_ok=True)
        with open(OBJECT_STORE_LOGGING_CONF_PATH, "w") as f:
            f.write(OBJECT_STORE_LOGGING_CONF)
        logger.info("Wrote %s", OBJECT_STORE_LOGGING_CONF_PATH)

    # --- service management ---

    def _restart_services(self):
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        for svc in (DATAMOVER_SERVICE, DMS_SERVICE):
            subprocess.run(["systemctl", "enable", svc], check=True)
            subprocess.run(["systemctl", "restart", svc], check=True)
            logger.info("Restarted %s", svc)


if __name__ == "__main__":
    ops.main(TrilioDataMoverSunbeamCharm)
