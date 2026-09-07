#!/usr/bin/env python3
"""TrilioVault DataMover API Kubernetes charm for Sunbeam Canonical OpenStack.

Manages the dmapi service via Pebble inside a k8s pod on port 8784.
Requires wlm-service relation to trilio-wlm-k8s to obtain the WLM API endpoint.

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
  - wlm-service: custom interface — remote app databag. Keys: wlm-api-url, wlm-db-url.
"""

import json
import logging
import os
import socket
import time

import jinja2
import ops

logger = logging.getLogger(__name__)

CONTAINER = "trilio-dm-api"
CONFIG_PATH = "/etc/triliovault-datamover/triliovault-datamover-api.conf"
DMAPI_LOGGING_CONF_PATH = "/etc/triliovault-datamover/datamover_api_logging.conf"
DMAPI_API_PASTE_PATH = "/etc/triliovault-datamover/api-paste.ini"
DMS_CLIENT_CONF = "/etc/triliovault-dms/client.conf"
LOG_DIR = "/var/log/triliovault"

DMAPI_PORT = 8784
# Pebble service name, as declared in _update_pebble_layer().
DMAPI_PEBBLE_SERVICE = "dmapi-api"
# How long _wait_for_service() gives dmapi-api to settle into "active" before
# the unit reports itself blocked. replan() returns once Pebble has *started*
# the process, not once it has stayed up, so a service that exits on startup
# needs an explicit settle window to be observed.
SERVICE_START_TIMEOUT = 60
SERVICE_POLL_INTERVAL = 3
# Consecutive ACTIVE samples required before the service is called healthy.
# A single sample is worthless: replan() already returns with the service
# ACTIVE, so one look always succeeds and a process that dies seconds later --
# precisely the crash loop this guards against -- reads as healthy.
SERVICE_STABLE_SAMPLES = 4
# Service type/name confirmed from `openstack endpoint list` — same on all platforms:
#   Service Name=dmapi  Service Type=datamover
DMAPI_SERVICE_TYPE = "datamover"
DMAPI_SERVICE_NAME = "dmapi"
# Traefik ingress model+name — Traefik constructs the path as /{model}-{name}.
# Setting model="trilio" and name="dm-api" gives path /trilio-dm-api (no openstack- prefix).
DMAPI_INGRESS_MODEL = "trilio"
DMAPI_INGRESS_NAME = "dm-api"
CA_BUNDLE_PATH = "/usr/local/share/ca-certificates/ca-bundle.crt"
TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")



# Ensure the schema default character set is utf8mb3 before any table is created.
#
# The dmapi schema has no index wide enough to hit InnoDB's 3072-byte key limit
# today, so unlike the WLM database this is not fixing a current failure. It is
# here because RHOSO 18 settles the charset for BOTH databases the same way, in
# matching db-init jobs (_triliovault-wlm-db-init.sh.tpl and
# _triliovault-datamover-api-db-init.sh.tpl), and because leaving one of the two
# on MySQL 8's utf8mb4 default is a trap for whoever next adds a wide composite
# index here. The value differs from RHOSO 18's on purpose -- see the WLM charm
# for why utf8mb4 cannot hold these indexes on either platform. The WLM side shows what that failure looks like: a UNIQUE index
# over four String(255) columns costs 3060 bytes at 3 bytes/char and fits, but
# 4080 bytes at 4 bytes/char and fails with (1071) Specified key was too long,
# aborting the migration and leaving a half-built schema behind.
#
# ALTER DATABASE sets the default for tables created afterwards and never
# rewrites existing ones. That is exactly the semantic wanted on a fresh deploy:
# it runs before the migrations, on a schema with no tables yet, and is a no-op
# on every later hook once the default already matches. It is not a repair for a
# database whose tables were already built as utf8mb4 -- nothing here converts
# existing tables, and T4O on Sunbeam has no deployed installs to migrate.
DB_CHARSET_SCRIPT = """
import os, sys
import pymysql

db = os.environ["TVO_DB_NAME"]
conn = pymysql.connect(
    host=os.environ["TVO_DB_HOST"],
    port=int(os.environ["TVO_DB_PORT"]),
    user=os.environ["TVO_DB_USER"],
    password=os.environ["TVO_DB_PASSWORD"],
    database=db,
)
try:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA"
            " WHERE SCHEMA_NAME = %s",
            (db,),
        )
        row = cur.fetchone()
        current = row[0] if row else None

        # utf8 is MySQL's deprecated alias for utf8mb3; both are 3 bytes per
        # character and both satisfy the index, so neither needs changing.
        if current in ("utf8mb3", "utf8"):
            print("ALREADY " + str(current))
            sys.exit(0)

        # Only ever act on a schema with no tables in it. ALTER DATABASE changes
        # the default for tables created afterwards and leaves existing ones on
        # whatever they were built with, so running it against a populated schema
        # produces a mixed-charset database: new tables utf8mb3, old ones utf8mb4.
        # The next migration that joins or FKs across that boundary then fails
        # with "Illegal mix of collations" (errno 1267/3780). That is a worse
        # state than the one being fixed, and it would be reported as a success.
        #
        # This matters most for dmapi, whose schema builds fine under utf8mb4 and
        # so is already populated on every install made before this guard existed.
        cur.execute(
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = %s",
            (db,),
        )
        if cur.fetchone()[0]:
            print("POPULATED " + str(current))
            sys.exit(0)

        cur.execute(
            "ALTER DATABASE `" + db + "` CHARACTER SET utf8mb3"
            " COLLATE utf8mb3_general_ci"
        )
        conn.commit()
        print("CHANGED " + str(current) + " -> utf8mb3")
finally:
    conn.close()
"""


class TrilioDmApiK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_dm_api_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.leader_elected, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._on_upgrade_charm)
        self.framework.observe(self.on.update_status, self._on_update_status)
        for rel in ("database", "amqp", "identity_service", "wlm_service"):
            self.framework.observe(
                getattr(self.on, f"{rel}_relation_changed"), self._configure
            )
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
            self.on.identity_service_relation_joined, self._on_identity_service_relation_joined
        )
        self.framework.observe(
            self.on.receive_ca_cert_relation_changed, self._configure
        )

    # --- event handlers ---

    def _on_pebble_ready(self, event):
        self._configure(event)

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
        """Write rabbitmq requirer credentials to app databag so rabbitmq-k8s provisions them."""
        if self.unit.is_leader():
            event.relation.data[self.app]["username"] = "dmapi"
            event.relation.data[self.app]["vhost"] = "dmapi"

    def _on_database_relation_joined(self, event):
        """Write mysql requirer database name so mysql-k8s provisions the database."""
        if self.unit.is_leader():
            event.relation.data[self.app]["database"] = "dmapi"

    def _on_identity_service_relation_joined(self, event):
        """Register DMAPI service endpoints with keystone on relation join."""
        self._register_keystone_service()

    def _send_relation_requests(self):
        """Idempotently write relation requests in case joined events were missed."""
        if not self.unit.is_leader():
            return
        amqp_rel = self.model.get_relation("amqp")
        if amqp_rel and not amqp_rel.data[self.app].get("username"):
            amqp_rel.data[self.app]["username"] = "dmapi"
            amqp_rel.data[self.app]["vhost"] = "dmapi"
        db_rel = self.model.get_relation("database")
        if db_rel:
            db_rel.data[self.app]["database"] = "dmapi"
        ks_rel = self.model.get_relation("identity-service")
        if ks_rel and not ks_rel.data[self.app].get("service-endpoints"):
            self._register_keystone_service()

    def _on_update_status(self, event):
        """Re-check the workload so a failed start cannot latch forever.

        _configure() sets BlockedStatus when dmapi-api will not stay up, and
        this charm observes no other periodic event -- so without this the unit
        would keep reporting blocked long after Pebble's own backoff retry
        succeeded, until some unrelated hook happened to fire. Cheap in the
        healthy case: one Pebble sample, no reconfigure.
        """
        container = self.unit.get_container(CONTAINER)
        if not container.can_connect() or self._missing_relations():
            return
        if self._service_is_active(container):
            self.unit.status = ops.ActiveStatus("DM-API ready")
            return
        logger.warning(
            "%s not active at update-status; reconfiguring", DMAPI_PEBBLE_SERVICE
        )
        self._configure(event)

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
        if self.unit.is_leader():
            self._db_sync(container)
        self._update_pebble_layer(container)
        self.unit.open_port("tcp", DMAPI_PORT)

        if self.unit.is_leader():
            self._register_keystone_service()

        if not self._wait_for_service(container):
            self.unit.status = ops.BlockedStatus(
                f"{DMAPI_PEBBLE_SERVICE} is not running; check "
                f"'pebble logs {DMAPI_PEBBLE_SERVICE}' in the {CONTAINER} container"
            )
            return

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
        """rabbitmq interface: provider writes hostname/password into its app databag."""
        rel = self.model.get_relation("amqp")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        host = d.get("hostname") or d.get("host")
        if host and d.get("password"):
            return {**dict(d), "host": host}
        return None

    def _identity_data(self):
        """keystone interface: provider writes into its app databag; credentials via Juju secret."""
        rel = self.model.get_relation("identity-service")
        if not rel or not rel.app:
            return None
        d = rel.data[rel.app]
        secret_id = d.get("service-credentials")
        if not secret_id or not d.get("service-host"):
            return None
        try:
            creds = self.model.get_secret(id=secret_id).get_content(refresh=True)
        except Exception:
            return None
        return {
            "service_host": d.get("service-host"),
            "service_port": d.get("service-port", "5000"),
            "service_protocol": d.get("service-protocol", "http"),
            "service_username": creds.get("username"),
            "service_password": creds.get("password"),
            "service_tenant": d.get("service-project-name", "services"),
            "service_domain_name": d.get("service-domain-name", "Default"),
        }

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
            return {"REQUESTS_CA_BUNDLE": CA_BUNDLE_PATH}
        return {}

    def _write_ca_cert(self, container):
        """Write CA bundle into the container and refresh the system trust store.

        Must match CA_BUNDLE_PATH (.crt) — _write_config()'s cafile= setting
        (line ~303) points there, and dmapi's own outbound requests (e.g. the
        contego_vast_instance relay) read this exact path directly. Writing a
        differently-named file here left cafile= pointing at a file that never
        existed, causing "Could not find a suitable TLS CA certificate bundle"
        on every outbound HTTPS call once a CA cert was actually configured.
        """
        ca_cert = self._get_ca_cert()
        if not ca_cert:
            return
        container.push(
            CA_BUNDLE_PATH,
            ca_cert,
            make_dirs=True,
        )
        container.exec(["update-ca-certificates"]).wait()
        logger.info("CA bundle written to container")

    def _wait_for_service(self, container):
        """True once Pebble reports dmapi-api genuinely active.

        container.replan() returns as soon as Pebble has started the service,
        not once it has stayed up. A service that exits immediately -- an
        unreadable log file, a bad config -- leaves Pebble retrying in the
        background while the charm happily reports ActiveStatus. That is what
        let a crash-looping replica sit in the Kubernetes Service endpoints
        refusing roughly a third of every WLM call to DM-API, with nothing in
        "juju status" to show for it.
        """
        deadline = time.monotonic() + SERVICE_START_TIMEOUT
        stable = 0
        while True:
            if self._service_is_active(container):
                stable += 1
                if stable >= SERVICE_STABLE_SAMPLES:
                    return True
            else:
                stable = 0
            if time.monotonic() >= deadline:
                logger.error(
                    "%s did not stay active for %s consecutive checks within %ss",
                    DMAPI_PEBBLE_SERVICE, SERVICE_STABLE_SAMPLES,
                    SERVICE_START_TIMEOUT,
                )
                return False
            time.sleep(SERVICE_POLL_INTERVAL)

    def _service_is_active(self, container):
        """Single-sample: is dmapi-api ACTIVE right now?"""
        try:
            service = container.get_service(DMAPI_PEBBLE_SERVICE)
        except (ops.pebble.ConnectionError, ops.ModelError) as e:
            logger.warning("could not query %s: %s", DMAPI_PEBBLE_SERVICE, e)
            return False
        return service.current == ops.pebble.ServiceStatus.ACTIVE

    def _ensure_db_charset(self, container):
        """Pin the database default charset to utf8mb3 before migrations run.

        See DB_CHARSET_SCRIPT for why: preventative here rather than a fix for a
        current failure, and consistent with how every other distro provisions
        both T4O databases.

        Credentials go through the environment rather than argv so they do not
        appear in the container's process list.
        """
        db = self._db_data()
        if not db:
            logger.warning("no database relation data; skipping charset check")
            return

        endpoint = db["endpoints"].split(",")[0].strip()
        db_host, _, db_port = endpoint.partition(":")

        try:
            out, _ = container.exec(
                ["python3", "-c", DB_CHARSET_SCRIPT],
                environment={
                    "TVO_DB_HOST": db_host,
                    "TVO_DB_PORT": db_port or "3306",
                    "TVO_DB_USER": db["username"],
                    "TVO_DB_PASSWORD": db["password"],
                    "TVO_DB_NAME": db["database"],
                },
            ).wait_output()
        except ops.pebble.ExecError as e:
            # Do not fail the hook on this. A transient database blip during a
            # mysql-k8s rolling restart, or a grant without database-level ALTER,
            # would otherwise wedge the unit here. If the charset genuinely is
            # wrong, the migration that runs next says so in its own terms.
            logger.warning("could not verify database charset: %s", e)
            return

        out = (out or "").strip()
        for line in out.splitlines():
            if line.startswith("CHANGED"):
                logger.info("database charset %s", line[len("CHANGED "):])
            elif line.startswith("ALREADY"):
                logger.debug("database charset already %s", line[len("ALREADY "):])
            elif line.startswith("POPULATED"):
                # Deliberately not "fixed" here -- see DB_CHARSET_SCRIPT. Saying
                # so plainly beats a silent ALTER that reports success and breaks
                # the next migration instead.
                logger.warning(
                    "database already contains tables and its default charset is"
                    " %s, not utf8mb3; leaving it alone. Tables already built"
                    " cannot be converted by ALTER DATABASE, so a schema created"
                    " before this guard stays as it is. To move it, drop the"
                    " database and redeploy.",
                    line[len("POPULATED "):],
                )

    def _db_sync(self, container):
        """Run DMAPI database migrations (idempotent; leader only).

        DMAPI uses dmapi-dbsync (not dmapi-manage db_sync). The tool reads the
        database connection from [database].connection in CONFIG_PATH.
        """
        self._ensure_db_charset(container)
        # Runs as root, like the service itself and like every other charm's
        # migration. dmapi-dbsync shares log_config_append with dmapi-api, so
        # it creates the log file root-owned if missing -- which is now simply
        # correct rather than a hazard.
        container.exec(
            ["/usr/bin/dmapi-dbsync", "--config-file", CONFIG_PATH],
        ).wait()
        logger.info("dmapi-dbsync completed")

    # --- config file rendering ---

    def _render_template(self, template_name: str, context: dict) -> str:
        """Render a Jinja2 template from src/templates/."""
        loader = jinja2.FileSystemLoader(TEMPLATE_DIR)
        env = jinja2.Environment(loader=loader, keep_trailing_newline=True)
        return env.get_template(template_name).render(**context)

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
        cafile = CA_BUNDLE_PATH if self._get_ca_cert() else ""

        context = {
            "dmapi_workers": self.config["api-workers"],
            "transport_url": transport_url,
            "app_name": self.app.name,
            "dmapi_port": DMAPI_PORT,
            "my_ip": "0.0.0.0",
            "debug": str(self.config["debug"]).lower(),
            "dmapi_logging_conf_path": DMAPI_LOGGING_CONF_PATH,
            "wlm_endpoint": wlm["wlm-api-url"],
            "log_dir": LOG_DIR,
            "db_url": db_url,
            "auth_url": auth_url,
            "keystone_project_name": identity.get("service_tenant", "services"),
            "keystone_username": identity.get("service_username", "dmapi"),
            "keystone_password": identity["service_password"],
            "service_domain_name": identity.get("service_domain_name", "Default"),
            "cafile": cafile,
            "rabbit_quorum_queue": str(self.config.get("rabbit-quorum-queue", True)).lower(),
            "amqp_durable_queues": str(self.config.get("amqp-durable-queues", True)).lower(),
        }
        rendered = self._render_template("triliovault-datamover-api.conf.j2", context)
        container.push(CONFIG_PATH, rendered, make_dirs=True)
        logger.info("Wrote %s", CONFIG_PATH)
        container.push(
            DMAPI_LOGGING_CONF_PATH,
            self._render_template("datamover_api_logging.conf.j2", {}),
            make_dirs=True,
        )
        logger.info("Wrote %s", DMAPI_LOGGING_CONF_PATH)
        container.push(
            DMAPI_API_PASTE_PATH,
            self._render_template("api-paste.ini.j2", {}),
            make_dirs=True,
        )
        logger.info("Wrote %s", DMAPI_API_PASTE_PATH)

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
        context = {
            "rabbitmq_url": rabbitmq_url,
            "db_url": wlm.get("wlm-db-url", ""),
            "node_id": self.unit.name.replace("/", "-"),
            "log_level": "DEBUG" if self.config["debug"] else "INFO",
            "log_file": "/var/log/triliovault/trilio-dms-client.log",
        }
        rendered = self._render_template("triliovault-dms-client.conf.j2", context)
        container.push(DMS_CLIENT_CONF, rendered, make_dirs=True)
        logger.info("Wrote %s", DMS_CLIENT_CONF)

    # --- Pebble layer ---

    def _update_pebble_layer(self, container):
        # Runs as root -- Pebble's default for a Juju k8s sidecar, and now
        # deliberate. dm-api used to pin user/group to dmapi, which made it the
        # one Trilio service on Sunbeam not running as root and gave it a bug
        # class of its own: anything that touched a dm-api file as root
        # (dmapi-dbsync, via the log_config_append it shares with the service)
        # left that file unopenable by the service, crash-looping it behind an
        # "active" status. Root cannot be locked out of its own files, so the
        # failure mode is structurally gone rather than patched around.
        # See "Root-user architecture" in CLAUDE.md; TVAULT-7653.
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
        try:
            container.replan()
        except ops.pebble.ChangeError as e:
            # dmapi-api died inside Pebble's own start window. Letting this
            # propagate would error the hook, and the caller's BlockedStatus --
            # which names the log to read -- would never be set.
            logger.error("replan failed for %s: %s", DMAPI_PEBBLE_SERVICE, e)
            return
        logger.info("Pebble layer applied for dmapi-api")

    # --- endpoint / ingress publishing ---

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
        """Write DMAPI endpoint registration data into the identity-service relation.

        admin and internal endpoints use the direct k8s service URL so that
        cluster-internal callers (e.g. WLM) reach dm-api via ClusterIP rather
        than through the Traefik MetalLB IP, which is not reliably reachable
        from inside the cluster and carries a Traefik path prefix that complicates
        URL construction in the contego client.

        RHOSO18 pattern (reference): internal_endpoint = PROTOCOL://HOST:8784/v2
        — direct service DNS with no path prefix.

        public endpoint uses the Traefik-provided https:// URL for external access.
        """
        rel = self.model.get_relation("identity-service")
        if not rel or not self.unit.is_leader():
            return
        fallback = f"http://{self.app.name}:{DMAPI_PORT}"
        public_base = (
            self._get_ingress_url("ingress-public")
            or self._get_ingress_url("ingress-internal")
            or fallback
        )
        # Internal callers (WLM) use the direct k8s service URL — no Traefik.
        # This matches RHOSO18's endpoint pattern and avoids MetalLB hairpin issues.
        internal_base = fallback
        endpoints = [{
            "admin_url": f"{fallback}/v2",
            "description": "TrilioVault DataMover API",
            "internal_url": f"{internal_base}/v2",
            "public_url": f"{public_base}/v2",
            "service_name": DMAPI_SERVICE_NAME,
            "type": DMAPI_SERVICE_TYPE,
        }]
        rel.data[self.app].update({
            "service-endpoints": json.dumps(endpoints, sort_keys=True),
            "region": self.config.get("region", "RegionOne"),
        })

    def _publish_ingress(self, rel):
        """Write traefik_k8s ingress requirer data.

        Matches IngressPerAppRequirer from charms.traefik_k8s.v2.ingress:
        - Leader writes app databag: model, name, port (individual JSON-encoded keys).
        - Every unit writes its own unit databag: host, ip (required by Traefik's
          is_ready validation before it will publish the ingress URL back).

        strip-prefix: true tells Traefik to strip the /trilio-dmapi path prefix
        before forwarding to DMAPI pods, so the service always sees /v2/... paths.
        """
        # App databag — leader only.
        if self.unit.is_leader():
            if "data" in rel.data[self.app]:
                del rel.data[self.app]["data"]
            rel.data[self.app]["model"] = json.dumps(DMAPI_INGRESS_MODEL)
            rel.data[self.app]["name"] = json.dumps(DMAPI_INGRESS_NAME)
            rel.data[self.app]["port"] = json.dumps(DMAPI_PORT)
            rel.data[self.app]["strip-prefix"] = json.dumps(True)
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
    ops.main(TrilioDmApiK8sCharm)
