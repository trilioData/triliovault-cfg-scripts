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
│   └── trilio-data-mover/           # DataMover machine subordinate charm
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
- Pushes concatenated CA bundle to `/usr/local/share/ca-certificates/ca-bundle.pem` inside the container
- Runs `update-ca-certificates` in the container
- Sets `REQUESTS_CA_BUNDLE` env var on all Pebble services so Python's `requests` library trusts the CA

The DataMover machine charm writes the CA to the host (`/usr/local/share/ca-certificates/trilio-ca.crt`) and runs `update-ca-certificates` on the host.

### Logging
All services log to `/var/log/triliovault/` on the container/host. The logging conf is **pushed by the charm at configure time** — it is NOT baked into the Docker image. This allows updating log rotation and formatters without rebuilding images.

Additionally:
- `use_stderr = true` in oslo.log config — Pebble captures stderr, making `kubectl logs` work
- `log_config_append = <path>` points to the per-service Python logging conf pushed by the charm
- Log formatter classes: `workloadmgr.openstack.common.log.UTCFormatter`, `dmapi.common.log.UTCFormatter`, `contego.common.log.UTCFormatter`, `s3fuse.log.UTCFormatter`

### wlm-cron singleton constraint
Only ONE instance of `wlm-cron` must run cluster-wide. The charm enforces this by setting `startup: disabled` for wlm-cron on non-leader units. Multiple wlm-cron instances cause duplicate scheduled job execution and corrupt workload state in the database.

### DMS node_id
- **Control plane (trilio-dms-k8s)**: `node_id` is the k8s node hostname, injected via the Kubernetes Downward API as `K8S_NODE_NAME` env var in the workload container (`charmcraft.yaml` `envConfig`). The charm reads it via `container.exec(["printenv", "K8S_NODE_NAME"])`. Do NOT use `socket.gethostname()` (returns pod name) or `self.unit.name` (returns Juju unit name).
- **Data plane (trilio-data-mover)**: `node_id` is `socket.getfqdn()`, matching what `openstack-hypervisor` charm sets as `node.fqdn` in snap config for nova-compute. Must match `OS-EXT-SRV-ATTR:host` from nova.

### DMS systemd units (data plane)
Neither `python3-trilio-dms` nor `tvault-contego` packages ship systemd unit files (both were designed for kolla containers). The `trilio-data-mover` charm writes both units to `/lib/systemd/system/` during install:
- `triliovault-dms.service` — runs `trilio-dms-server` as nova user
- `tvault-contego.service` — runs tvault-contego with nova.conf from the openstack-hypervisor snap at `/var/snap/openstack-hypervisor/current/etc/nova/nova.conf`

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
| `identity-service` | `keystone` | keystone-k8s | Req writes `service-endpoints` (JSON), `region` to **app** databag (leader only); prov writes `service-host`, `service-credentials` (Juju secret) to prov **app** databag |
| `receive-ca-cert` | `certificate_transfer` | vault-k8s / self-signed | Prov writes `ca` to unit databag |
| `wlm-service` | custom | trilio-wlm-k8s | Provider writes `wlm-api-url` to app databag |
| `ingress-internal` | `traefik_k8s` v2 | traefik-k8s | Req writes `model`, `name`, `port`, `scheme` to app databag |

---

## Service Ports

| Service | Port | Keystone service type | Keystone service name |
|---|---|---|---|
| WLM API | 8781 | `workloads` | `TrilioVaultWLM` |
| DMAPI | 8784 | `datamover` | `dmapi` |
| DMS server | (no HTTP; RabbitMQ only) | — | — |

WLM endpoint URL format: `http://<app>:8781/v1/$(tenant_id)s`
DMAPI endpoint URL format: `http://<app>:8784/v2`

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
