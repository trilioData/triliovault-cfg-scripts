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



class TrilioDmApiK8sCharm(ops.CharmBase):

    def __init__(self, *args):
        super().__init__(*args)
        self.framework.observe(self.on.trilio_dm_api_pebble_ready, self._on_pebble_ready)
        self.framework.observe(self.on.config_changed, self._configure)
        self.framework.observe(self.on.leader_elected, self._configure)
        self.framework.observe(self.on.upgrade_charm, self._on_upgrade_charm)
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
        self._ensure_log_permissions(container)
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

    def _ensure_log_permissions(self, container):
        """Force LOG_DIR (and its contents) back to dmapi:dmapi ownership.

        The Dockerfile chowns this directory at build time, but the pebble
        service always runs as user=dmapi/group=dmapi (_update_pebble_layer),
        so any log file that ends up root-owned at runtime (e.g. left behind
        from a period where the container ran as root) makes oslo_log's
        FileHandler fail with PermissionError on every startup. dmapi-api then
        exits immediately, pebble restarts it, and it fails again in a ~30s
        crash loop — silently, since the process never gets far enough to log
        anywhere but stdout. Re-chown on every _configure() run so this
        self-heals regardless of how the file got into a bad state.
        """
        container.exec(["chown", "-R", "dmapi:dmapi", LOG_DIR]).wait()

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
        # Pin to the dmapi user (created by python3-dmapi's own postinst;
        # the Dockerfile chown -R dmapi:dmapi on its data directories).
        # Juju's k8s sidecar packaging otherwise runs Pebble services as root
        # by default, overriding the image's own "USER dmapi" directive.
        # dm-api is out of scope for the WLM/DMS/datamover root-vs-nova
        # experiment (see nova-user-known-good-state.md) — it doesn't touch
        # the shared NFS backup-target filesystem, so it always runs as its
        # own dmapi user regardless of how that experiment concludes.
        layer = ops.pebble.Layer({
            "summary": "TrilioVault DM-API",
            "services": {
                "dmapi-api": {
                    "override": "replace",
                    "summary": "DataMover API",
                    "command": f"/usr/bin/dmapi-api --config-file {CONFIG_PATH}",
                    "startup": "enabled",
                    "environment": self._get_ca_bundle_env(),
                    "user": "dmapi",
                    "group": "dmapi",
                }
            },
        })
        container.add_layer(CONTAINER, layer, combine=True)
        container.replan()
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
