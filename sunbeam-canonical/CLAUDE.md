# sunbeam-canonical — Trilio for OpenStack on Sunbeam Canonical OpenStack

## Overview

Sunbeam is Canonical's opinionated, single-command OpenStack distribution built on MicroK8s + Juju.
This directory contains the native Juju charm implementation for T4O on Sunbeam (`tv7404-native` branch).

**Reference repos cloned in `C:\vscode-workspace\`:**
- `sunbeam-charms` — upstream Sunbeam Juju charms (https://opendev.org/openstack/sunbeam-charms)
- `snap-openstack` — the `sunbeam` CLI snap (https://opendev.org/openstack/snap-openstack)

---

## Architecture

### Sunbeam deployment model

| Layer | Technology |
|-------|-----------|
| Container orchestration | MicroK8s (single-node or multi-node) |
| Charm lifecycle | Juju (`openstack` k8s model + `openstack-machines` machine model) |
| Service packaging | OCI images (one per Trilio service) |
| Control plane charm framework | `ops` library + Pebble (NOT charms_openstack/reactive) |
| Data plane (DataMover) | Machine subordinate charm, subordinate to `openstack-hypervisor` |
| Deployment orchestration | `sunbeam` CLI → Terraform → Juju |

### T4O Sunbeam charm layout

```
sunbeam-canonical/
├── charms/
│   ├── trilio-wlm-k8s/              # WLM k8s charm (ops + Pebble)
│   ├── trilio-dm-api-k8s/           # DMAPI k8s charm (ops + Pebble)
│   ├── trilio-dms-k8s/              # DMS server k8s charm (ops + Pebble)
│   └── trilio-data-mover-sunbeam/   # DataMover machine subordinate charm
├── docker/
│   ├── trilio-wlm/Dockerfile        # OCI image for WLM (wlm-api/workloads/scheduler/cron)
│   ├── trilio-datamover-api/Dockerfile
│   ├── trilio-dms/Dockerfile        # OCI image for DMS server (k8s side)
│   ├── trilio-horizon-plugin/Dockerfile_2024.1  # Trilio Horizon Plugin (extends ghcr.io/canonical/horizon)
│   ├── devops-build-publish.sh      # Primary build+publish script (supports all 4 images)
│   └── build_images.sh              # Legacy build script (APT-repo substitution, 3 images)
├── trilio-bundle.yaml               # Juju bundle for control plane (openstack model)
├── trilio-dataplane-bundle.yaml     # Juju bundle for data plane (openstack-machines model)
└── CLAUDE.md                        # This file
```

---

## Key Technical Concepts

### ops + Pebble pattern (k8s charms)
Unlike the existing `juju-charms/` which use `charms_openstack` (reactive), the Sunbeam k8s charms use:
- `ops.CharmBase` directly — no reactive states, no charms_openstack
- Pebble for service lifecycle inside the container (`container.add_layer()`, `container.replan()`)
- `container.exec([...]).wait()` for running commands inside the pod (DB sync, CA cert update)
- Events: `pebble_ready`, `config_changed`, `<rel>_relation_joined`, `<rel>_relation_changed`

### Resource provisioning via Juju relation protocol
In Sunbeam, **the Juju operators handle resource provisioning automatically** — no manual shell commands needed:

| Resource | How it's provisioned |
|---|---|
| RabbitMQ user + vhost | Requirer writes `username` + `vhost` to **app** databag (leader only) on `amqp_relation_joined`; rabbitmq-k8s creates them |
| MySQL database + user | Requirer writes `{"database": "<name>"}` to **app** databag (leader only) on `database_relation_joined`; mysql-k8s creates them |
| Keystone service user + endpoints | Requirer writes `service-endpoints` (JSON array) + `region` to **app** databag (leader only); keystone-k8s creates service user and endpoints, responds with `service-credentials` (Juju secret) |

This is fundamentally different from Kolla (which runs `mysql_user` Ansible module and `openstack endpoint create`) or RHOSO18 (which runs init Jobs). In Sunbeam, writing to the relation databag IS the provisioning request.

### DB synchronisation
WLM and DMAPI require DB schema migration on first deploy and upgrades.

| Service | Command | Notes |
|---------|---------|-------|
| WLM | `alembic --config /etc/triliovault-wlm/triliovault-wlm.conf upgrade head` | Requires `[alembic]` section in the conf with `sqlalchemy.url`, `script_location`, `version_locations` |
| DMAPI | `/usr/bin/dmapi-dbsync --config-file /etc/triliovault-datamover/triliovault-datamover-api.conf` | Reads `[database].connection` from conf |

**Do NOT use `wlm-manage db_sync` or `dmapi-manage db_sync`** — these are incorrect. WLM uses alembic, DMAPI uses `dmapi-dbsync`.

Run only on the leader unit (idempotent — safe to re-run). Follows the `ops_sunbeam` pattern: `run_db_sync()` calls `container.exec(cmd).wait()`, leader-only, retries on timeout.

### TLS / CA certificate handling (k8s charms)
All three k8s charms support the `receive-ca-cert` relation (`certificate_transfer` interface):
- Requirer reads `ca` key from each provider unit databag
- Pushes concatenated CA bundle to `/usr/local/share/ca-certificates/ca-bundle.crt` inside the container (must be `.crt`, not `.pem` — `update-ca-certificates` only processes `*.crt` files)
- Runs `update-ca-certificates` in the container
- Sets `REQUESTS_CA_BUNDLE` env var on all Pebble services so Python's `requests` library trusts the CA

**`receive-ca-cert` is required for all Sunbeam Trilio k8s charms** — without it, keystonemiddleware fails TLS verification when calling the Keystone HTTPS public endpoint, returning 503 "Keystone service temporarily unavailable" on every API request. Add `juju relate trilio-wlm-k8s:receive-ca-cert keystone:send-ca-cert` (and same for dmapi/dms) on fresh deployments.

The DataMover machine charm writes the CA to the host (`/usr/local/share/ca-certificates/trilio-ca.crt`) and runs `update-ca-certificates` on the host.

### Logging
All services log to `/var/log/triliovault/` on the container/host. The logging conf is **pushed by the charm at configure time** — it is NOT baked into the Docker image. This allows updating log rotation and formatters without rebuilding images.

Additionally:
- `use_stderr = true` in oslo.log config — Pebble captures stderr, making `kubectl logs` work
- `log_config_append = <path>` points to the per-service Python logging conf pushed by the charm
- Log formatter classes: `workloadmgr.openstack.common.log.UTCFormatter`, `dmapi.common.log.UTCFormatter`, `contego.common.log.UTCFormatter`, `s3fuse.log.UTCFormatter`

### workloadmgr CLI in Pebble exec — setsid required
When the WLM charm runs `workloadmgr` via `container.exec()` (Pebble), the process inherits Pebble's controlling terminal (the container's `/dev/console`). `workloadmgr`'s cliff/cmd2 layer opens `/dev/tty` and calls `curses.cbreak()`, which fails on the container console with "cbreak() returned ERR".

Fix: prefix the command with `setsid` — e.g. `["setsid", "workloadmgr", ...]`. `setsid` creates a new session with no controlling terminal, so `/dev/tty` open fails with ENXIO and cmd2 skips curses init gracefully.

This issue does NOT appear with `kubectl exec -- bash -c '...'` because that path starts processes without a controlling terminal in the container, whereas Pebble (as container PID 1) inherits one from the kubelet.

### api-paste.ini — charm must overwrite package file
The `api-paste.ini` shipped by the `workloadmgr` deb package contains legacy `%SERVICE_TENANT_NAME%`, `%SERVICE_USER%`, `%SERVICE_PASSWORD%` placeholders. Python's `configparser` raises `InterpolationSyntaxError` on `%` that aren't valid `%(var)s` interpolation, crashing wlm-api on startup. Fix: the WLM charm writes a clean `WLM_API_PASTE` constant directly to `/etc/triliovault-wlm/api-paste.ini` in `_write_config()`, overwriting the package-shipped file. The removed `[filter:authtoken]` password fields are NOT needed — keystonemiddleware reads auth from `[keystone_authtoken]` in the main conf.

### keystone_authtoken domain — read from identity-service relation, not hardcoded
WLM and DMAPI use `[keystone_authtoken]` with `user_domain_name` and `project_domain_name`. On Sunbeam, keystone-k8s creates service users in `service_domain`, **not** `Default`. The charms read `service-domain-name` from the identity-service relation app databag and pass it as `service_domain_name` to the config template. **Do NOT hardcode `Default`** — this causes keystonemiddleware 401 on the service-user auth call → 503 "Keystone service temporarily unavailable" on every API request.

### sql_connection in [DEFAULT] — not [database]
WLM reads the DB URL from `sql_connection` in the `[DEFAULT]` section, **not** from `connection` in `[database]`. All other deployment methods (RHOSP17, RHOSO18, Kolla) all use `sql_connection` in `[DEFAULT]`. The `[database]` section with `connection` key is a newer Oslo convention that WLM does not use. Both must be present: `[DEFAULT].sql_connection` for WLM's own DB access, and `[alembic].sqlalchemy.url` for alembic migrations.

### RabbitMQ user/vhost for WLM: `wlm` (not `workloadmgr`)
The RabbitMQ user and vhost for WLM are named `wlm`/`wlm` — created by the previous Juju charm version (charm-trilio-wlm from juju-charms/). The Sunbeam charm must request `username=wlm`, `vhost=wlm` in the amqp relation databag. Using `workloadmgr` for username/vhost causes `(403) ACCESS_REFUSED` from RabbitMQ because that user was never created. The database name (MySQL) and binary name remain `workloadmgr`.

### wlm-cron singleton constraint
Only ONE instance of `wlm-cron` must run cluster-wide. The charm enforces this by setting `startup: disabled` for wlm-cron on non-leader units. Multiple wlm-cron instances cause duplicate scheduled job execution and corrupt workload state in the database.

### DMS node_id
- **Control plane (trilio-dms-k8s)**: `node_id` is the k8s node hostname, injected via the Kubernetes Downward API as `K8S_NODE_NAME` env var in the workload container (`charmcraft.yaml` `envConfig`). The charm reads it via `container.exec(["printenv", "K8S_NODE_NAME"])`. Do NOT use `socket.gethostname()` (returns pod name) or `self.unit.name` (returns Juju unit name).
- **Data plane (trilio-data-mover)**: `node_id` is `socket.getfqdn()`, matching what `openstack-hypervisor` charm sets as `node.fqdn` in snap config for nova-compute. Must match `OS-EXT-SRV-ATTR:host` from nova.

### DMS systemd units (data plane)
Neither `python3-trilio-dms` nor `tvault-contego` packages ship systemd unit files (both were designed for kolla containers). The `trilio-data-mover` charm writes both units to `/lib/systemd/system/` during install:
- `triliovault-dms.service` — runs `trilio-dms-server` as nova user, with `PYTHONPATH=/snap/openstack-hypervisor/current/usr/lib/python3/dist-packages` so it can import nova/kombu from the snap
- `triliovault-datamover.service` — runs tvault-contego as nova user with the same PYTHONPATH, using `--config-file=/etc/triliovault-datamover/nova.conf` (our patched copy) and `--config-file=/etc/triliovault-datamover/triliovault-datamover.conf`

### nova.conf and CA cert handling (data plane)
The `openstack-hypervisor` snap's nova.conf is at `/var/snap/openstack-hypervisor/common/etc/nova/nova.conf` (root:root 640 — unreadable by the nova user). The charm copies it to `/etc/triliovault-datamover/nova.conf` (root:nova 640).

**Only one line is patched in the copy**: the `cafile=` line in `[keystone_authtoken]` (and any other section) that references a snap-internal path (`/var/snap/openstack-hypervisor/.../receive-ca-bundle.pem`, also root:root 640). It is rewritten to `/etc/triliovault-datamover/ca-bundle.pem`.

The CA cert at that path comes from the **`receive-ca-cert` Juju relation** — NOT copied from the snap. `_write_ca_cert()` reads the CA from the relation databag and writes it to:
1. `/etc/triliovault-datamover/ca-bundle.pem` (root:nova 640) — for tvault-contego's direct use via `cafile=`
2. `/usr/local/share/ca-certificates/trilio-ca.crt` + `update-ca-certificates` — system trust store for all other tools

**Ordering in `_configure()`**: `_write_ca_cert()` must run before `_sync_nova_conf()` so the CA file exists before nova.conf references it.

If the `receive-ca-cert` relation has no data yet, the `cafile=` line is stripped entirely so keystoneauth1 falls back to the world-readable system CA trust store.

### DMS client conf (data plane only)
`/etc/triliovault-dms/client.conf` is written by the `trilio-data-mover` charm when `wlm-db-url` config is set. It contains WLM DB URL, same RabbitMQ credentials as DMS server, and `node_id = socket.getfqdn()`. Control plane charms (WLM, DMAPI) do not get a DMS client conf in the current implementation.

---

## sunbeam CLI (snap-openstack)

The `sunbeam` CLI snap (`C:\vscode-workspace\snap-openstack`) orchestrates the full OpenStack deployment:
- Uses **Terraform** plans to manage Juju application deployments
- Uses **manifest YAML files** to declare which charm channels to deploy (see `manifests/2024.1/stable.yml`)
- Does NOT directly handle DB sync, RabbitMQ user creation, or Keystone endpoint registration — those are charm responsibilities
- Provides `juju.exec(cmd, unit=name)` utility for running commands on units if needed externally

Key directories in snap-openstack:
- `sunbeam-python/sunbeam/core/` — core utilities (juju.py, terraform.py, steps.py, openstack.py)
- `sunbeam-python/sunbeam/features/` — per-feature deployment modules
- `manifests/` — per-release channel manifests declaring charm versions
- `cloud/` — Terraform modules for Juju deployment

---

## ops_sunbeam Framework (sunbeam-charms)

The upstream glance-k8s and other Sunbeam charms use `ops_sunbeam` (`C:\vscode-workspace\sunbeam-charms\ops-sunbeam\`), which provides:
- `OSBaseOperatorCharmK8S` — base class with `run_db_sync()`, `configure_unit()`, `configure_containers()`
- `db_sync_cmds` — list of commands to run for DB migration (retried up to 10x with exponential backoff, leader-only)
- `_retry_db_sync(cmd)` — wraps `container.exec(cmd)` with tenacity retry
- Relation handlers in `relation_handlers.py` for amqp, mysql_client, identity-service, certificate_transfer

Our Trilio k8s charms use **plain `ops`** (not `ops_sunbeam`) to avoid the framework dependency. The patterns are equivalent but implemented manually.

---

## Relation Interfaces

| Relation | Interface | Provider | Requirer key fields |
|---|---|---|---|
| `database` | `mysql_client` | mysql-k8s | Req writes `database` to app databag; prov writes `endpoints`, `username`, `password` |
| `amqp` | `rabbitmq` | rabbitmq-k8s | Req writes `username`, `vhost` to **app** databag (leader only); prov writes `hostname`, `password` to prov **app** databag |
| `identity-service` | `keystone` | keystone-k8s | Req writes `service-endpoints` (JSON), `region` to **app** databag (leader only); prov writes `service-host`, `service-port`, `service-protocol`, `service-project-name`, `service-domain-name`, `service-credentials` (Juju secret) to prov **app** databag |
| `receive-ca-cert` | `certificate_transfer` | vault-k8s / self-signed | Prov writes `ca` to unit databag |
| `wlm-service` | custom | trilio-wlm-k8s | Provider writes `wlm-api-url` to app databag |
| `ingress-internal` | `traefik_k8s` v2 | traefik-k8s | Req writes `model`, `name`, `port`, `scheme` to app databag; prov writes `{"ingress": '{"url": "https://IP:443/model-app"}'}` to prov **app** databag |
| `ingress-public` | `traefik_k8s` v2 | traefik-public | Same as ingress-internal but routed via traefik-public for external access |

---

## Service Ports

| Service | Port | Keystone service type | Keystone service name |
|---|---|---|---|
| WLM API | 8781 | `workloads` | `TrilioVaultWLM` |
| DMAPI | 8784 | `datamover` | `dmapi` |
| DMS server | (no HTTP; RabbitMQ only) | — | — |

WLM endpoint URL format (public/internal): `https://IP/openstack-trilio-wlm/v1/$(tenant_id)s` (via Traefik), falls back to `http://trilio-wlm-k8s:8781/v1/$(tenant_id)s`
DMAPI endpoint URL format (public/internal): `https://IP/openstack-trilio-dm-api/v2` (via Traefik), falls back to `http://trilio-dm-api-k8s:8784/v2`
Admin URL is always the plain k8s service address (Traefik does not route admin traffic).

The ingress `name` sent to Traefik is a **fixed constant** (`trilio-wlm`, `trilio-dm-api`) — NOT `self.app.name`. This drops the `-k8s` suffix to match OpenStack's endpoint naming convention (nova, glance, etc. all omit the `-k8s` charm suffix). The Traefik path becomes `/openstack-<name>`.

### Traefik ingress databag format (requirer side)
Traefik v2 `IngressPerAppRequirer` expects **individual top-level keys** — NOT a single nested `data` JSON blob. Port must be a JSON-encoded integer. Additionally, **every unit** must write `host` and `ip` to its own unit databag or Traefik's `is_ready` check returns False and it wipes the ingress.

```python
# App databag — leader only
if self.unit.is_leader():
    rel.data[self.app]["model"] = json.dumps(self.model.name)   # e.g. '"openstack"'
    rel.data[self.app]["name"]  = json.dumps(WLM_INGRESS_NAME)  # '"trilio-wlm"'
    rel.data[self.app]["port"]  = json.dumps(WLM_PORT)          # '8781'

# Unit databag — every unit (not just leader)
binding = self.model.get_binding(rel)
ip = str(binding.network.bind_address) if binding and binding.network.bind_address else None
rel.data[self.unit]["host"] = json.dumps(socket.getfqdn())
if ip:
    rel.data[self.unit]["ip"] = json.dumps(ip)
```

Writing a nested `data` key (e.g. `rel.data[self.app]["data"] = json.dumps({...})`) causes Traefik to silently ignore the requirer as not ready and wipe its own ingress response.

### Traefik ingress URL pattern (provider response)
Traefik writes the routed URL into the ingress relation app databag as:
```
rel.data[rel.app]["ingress"] = '{"url": "https://IP/openstack-trilio-wlm"}'
```
Read it with: `json.loads(rel.data[rel.app].get("ingress", "{}")).get("url")`.
Charms must observe `ingress_*_relation_changed` (not just `_joined`) to re-register Keystone endpoints once Traefik has written this URL — Traefik writes the URL asynchronously after the requirer joins.

### dispatch file permissions
The `dispatch` file in machine subordinate charms MUST be stored with execute permission (`100755`) in git. Windows git clones silently drop the x-bit — always verify with `git ls-files -s dispatch` (should show `100755`). If it shows `100644`, run `git update-index --chmod=+x dispatch` and commit. Without the x-bit, Juju logs "exec: dispatch: permission denied" on every hook invocation.

---

## Building and Publishing

### Build server

| Field | Value |
|---|---|
| IP | 172.26.2.2 |
| User | ubuntu (key-based SSH) |
| OS | Ubuntu 24.04 LTS |
| Tools | juju 3.6.25, kubectl 1.32.13, canonical k8s snap |
| k8s cluster | 3-node HA (172.26.2.2, .3, .4); Juju controller: `sunbeam-controller` |
| Machine model | Juju controller: `localhost-localhost` |

### Trilio APT repository

```
deb [trusted=yes] https://apt.fury.io/trilio-maint-6-2 /
```

### Docker images

All Dockerfiles live under `sunbeam-canonical/docker/<container-name>/`. The primary build script is `devops-build-publish.sh`.

```bash
# Build and push all 4 images (run from sunbeam-canonical/docker/ on build server)
bash devops-build-publish.sh \
  --tag 6.2.1-2024.1 \
  --containers all \
  --mode build-and-publish
```

The tag **must** follow the `<trilio-version>-<openstack-release>` format (e.g. `6.2.1-2024.1`) so the script can derive:
- `OPENSTACK_RELEASE=2024.1` — selects the release-specific Dockerfile (`Dockerfile_2024.1`) or falls back to `Dockerfile`
- `TRILIO_PIP_INDEX_URL` — PyPI index URL for the horizon plugin pip packages (derived as `https://pypi.fury.io/trilio-<major>-<minor>/`)

Images:
| Image | Dockerfile | Base | Service user |
|---|---|---|---|
| `docker.io/trilio/trilio-wlm-canonical:<tag>` | `docker/trilio-wlm/Dockerfile` | `ubuntu:jammy` + cloud-archive:caracal | `nova` (UID 42436) |
| `docker.io/trilio/trilio-datamover-api-canonical:<tag>` | `docker/trilio-datamover-api/Dockerfile` | `ubuntu:jammy` + cloud-archive:caracal | `dmapi` |
| `docker.io/trilio/trilio-dms-canonical:<tag>` | `docker/trilio-dms/Dockerfile` | `ubuntu:jammy` + cloud-archive:caracal | `nova` (UID 42436) |
| `docker.io/trilio/trilio-horizon-plugin-canonical:<tag>` | `docker/trilio-horizon-plugin/Dockerfile_2024.1` | `ghcr.io/canonical/horizon:2024.1` | default (root/www-data) |

#### OCI image design decisions (DO NOT CHANGE without reading this)

**Base image**: `ubuntu:jammy` (Ubuntu 22.04) — NOT Kolla images (`quay.io/openstack.kolla/*`), NOT OpenStack Helm images (`openstackhelm/*`). Sunbeam uses Canonical's Ubuntu-based OpenStack. Kolla/OSH base images carry Kolla-specific entrypoints and venvs that conflict with Pebble's process management.

**Ubuntu Cloud Archive (UCA)**: `cloud-archive:caracal` is added to get OpenStack Caracal (2024.1) packages (`nova-common`, `python3-nova`, `python3-novaclient`, `python3-neutronclient`, `python3-glanceclient`). Without UCA, Ubuntu 22.04's base repos only have OpenStack Yoga packages.

**nova user UID = 42436**: Confirmed from the running Sunbeam cluster (`kubectl exec -n openstack nova-0 -c nova-api -- id nova`). All other distros also use 42436 (Kolla enforces it; UCA creates nova at a different UID by default).

**`nova_userid.sh`**: Required because `nova-common` from UCA creates nova at a system-allocated UID (not 42436). The script deletes the existing nova user, recreates it at UID/GID 42436, and restores group memberships. Source: `docker/openstack-helm/trilio-wlm/nova_userid.sh`. Run this BEFORE installing Trilio packages.

**Service user mapping** (matches Kolla reference pattern):
| Service | User | Why |
|---|---|---|
| wlm-api, wlm-workloads, wlm-scheduler, wlm-cron | `nova` | WLM is a nova-adjacent service; file permissions on /var/lib/workloadmgr and mounts use nova |
| DMS server (k8s) | `nova` | DMS manages NFS/S3 mounts on behalf of nova-compatible services |
| DataMover API (dmapi) | `dmapi` | DMAPI is an independent control-plane service; dmapi user created by python3-dmapi package |

**nova-sudoers** (`nova ALL = (root) NOPASSWD: /usr/bin/workloadmgr-rootwrap *`): Required for WLM to execute privileged rootwrap operations (NFS mount/unmount, libvirt interactions).

**dmapi_sudoers** (`dmapi ALL=(ALL) NOPASSWD: ALL`): Full sudo for dmapi user, matching Kolla reference (`docker/kolla-ansible/trilio-datamover-api/dmapi_sudoers`).

**Horizon plugin**: Uses `ghcr.io/canonical/horizon:2024.1` (the Canonical Sunbeam Horizon image confirmed from running cluster). Installs `tvault-horizon-plugin`, `workloadmgrclient`, `contegoclient` via pip with `TRILIO_PIP_INDEX_URL`. This is release-specific — the Dockerfile is named `Dockerfile_2024.1`.

**`devops-build-publish.sh` for dev builds**: With a dev tag like `shyam-tv7404-10`, the script's tag parsing breaks (expects `<version>-<openstack>` format). For dev builds, run `docker build` directly with the correct Dockerfile and `--build-arg TRILIO_PIP_INDEX_URL=<url>` for horizon plugin.

### Charms (Charmhub)

All four charms are registered on Charmhub under the `triliodata` publisher:

| Charm | Type | Charmhub name |
|---|---|---|
| WLM k8s | k8s | `trilio-wlm-k8s` |
| DMAPI k8s | k8s | `trilio-dm-api-k8s` |
| DMS k8s | k8s | `trilio-dms-k8s` |
| DataMover machine | subordinate | `trilio-data-mover-sunbeam` |

Publish channel: **`latest/candidate`**

Build and publish workflow:
```bash
# On build server — pack each charm
cd sunbeam-canonical/charms/<charm-dir>
charmcraft pack

# Upload and release
charmcraft upload <charm>.charm --name <charm-name>
# Note the revision number from upload output, then:
charmcraft release <charm-name> --revision <N> --channel latest/candidate
```

> **Note:** `charmcraft login` requires a browser on first use. Run `charmcraft login --export creds.txt` locally, transfer `creds.txt` to the server, then `export CHARMCRAFT_AUTH=$(cat creds.txt)` before building.
