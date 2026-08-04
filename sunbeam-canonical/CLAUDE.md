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

## Mandatory Code Review Before Any Change

**Before making ANY change to a Sunbeam charm, review ALL charm files (`trilio-wlm-k8s`, `trilio-dm-api-k8s`, `trilio-data-mover-sunbeam`) for:**

1. **RabbitMQ username/vhost consistency** — every place that writes username/vhost to relation data must use the same value as every other place for that service. For WLM (main amqp): `workloadmgr`/`workloadmgr`. For WLM embedded DMS (amqp-dms): `dmapi`/`dmapi`. For DMAPI: `dmapi`/`dmapi`. For DataMover: `contego`/`dmapi`.
2. **Database name consistency** — every place writing the DB name must be consistent (`workloadmgr` for WLM, `dmapi` for DMAPI).
3. **`_send_relation_requests()` guard** — must have `if not rel.data[self.app].get("username"):` guard to avoid overwriting an already-provisioned relation. An unconditional overwrite rotates the RabbitMQ password and causes `(403) ACCESS_REFUSED` on every service that uses it.
4. **No hardcoded stale defaults** — check all `amqp.get('username', '<default>')` calls to ensure defaults match what was actually provisioned.
5. **Cross-check relation join handler vs `_send_relation_requests()`** — both must request the same username/vhost/database. Mismatches between them are the most common source of auth failures.

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

### workloadmgr CLI for testing — run from inside the WLM pod
When running `workloadmgr` commands for testing (e.g. `workload-create`, `workload-list`, `snapshot-create`, `snapshot-list`, `snapshot-show`), run them from **inside** the `trilio-wlm` container of any WLM pod, not from external nodes or from the build server. The external nodes lack the `workloadmgrclient` openstack plugin. The `openstack workload ...` CLI extension is only available inside the pod.

```bash
kubectl exec -n openstack trilio-wlm-k8s-0 -c trilio-wlm -- \
  setsid workloadmgr --os-auth-url http://10.152.183.175:5000/v3 \
    --os-username svc_trilio_wlm_k8s-... --os-password ... \
    --os-project-name services --os-user-domain-name service_domain \
    --os-project-domain-name service_domain snapshot-list
```

Or export the auth env vars inside the pod first and then run `workloadmgr <subcommand>`. The `setsid` prefix is required (see note below).

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

### RabbitMQ user/vhost for WLM: `workloadmgr` (not `wlm`)
The RabbitMQ user and vhost for WLM are `workloadmgr`/`workloadmgr`. The charm requests `username=workloadmgr`, `vhost=workloadmgr` in the `amqp` relation databag (set in `_on_amqp_relation_joined()` and consistently in `_send_relation_requests()`). The embedded DMS uses a separate `amqp-dms` relation requesting `username=dmapi`, `vhost=dmapi`. The database name (MySQL) and binary name are also `workloadmgr`.

**Critical — `_send_relation_requests()` must NOT unconditionally overwrite amqp relation data**: rabbitmq-k8s generates a fresh password whenever the requirer's `username` field changes. If `_send_relation_requests()` writes a different username from what `_on_amqp_relation_joined()` set, rabbitmq-k8s creates a new user with a new password while the charm config uses the old password → permanent `(403) ACCESS_REFUSED`. Guard the write with `if not amqp_rel.data[self.app].get("username"):` so it only writes on first use, never overwrites.

### wlm-cron singleton constraint
Only ONE instance of `wlm-cron` must run cluster-wide. The charm enforces this by setting `startup: disabled` for wlm-cron on non-leader units. Multiple wlm-cron instances cause duplicate scheduled job execution and corrupt workload state in the database.

### DMS node_id
- **Control plane (trilio-dms-k8s)**: `node_id` is the k8s node hostname, injected via the Kubernetes Downward API as `K8S_NODE_NAME` env var in the workload container (`charmcraft.yaml` `envConfig`). The charm reads it via `container.exec(["printenv", "K8S_NODE_NAME"])`. Do NOT use `socket.gethostname()` (returns pod name) or `self.unit.name` (returns Juju unit name).
- **Data plane (trilio-data-mover)**: `node_id` is `socket.getfqdn()`, matching what `openstack-hypervisor` charm sets as `node.fqdn` in snap config for nova-compute. Must match `OS-EXT-SRV-ATTR:host` from nova.

### DMS systemd units (data plane)
Neither `python3-trilio-dms` nor `tvault-contego` packages ship systemd unit files (both were designed for kolla containers). The `trilio-data-mover` charm writes both units to `/lib/systemd/system/` during install:
- `triliovault-dms.service` — runs `trilio-dms-server` as root, with `PYTHONPATH=/snap/openstack-hypervisor/current/usr/lib/python3/dist-packages` so it can import nova/kombu from the snap
- `triliovault-datamover.service` — runs tvault-contego as root with the same PYTHONPATH, using `--config-file=/etc/triliovault-datamover/nova.conf` (our patched copy) and `--config-file=/etc/triliovault-datamover/triliovault-datamover.conf`

**`StartLimitIntervalSec=0` is required in both unit `[Unit]` sections.** The systemd default allows only 5 starts in 10 seconds; an earlier version had an explicit `StartLimitIntervalSec=120 / StartLimitBurst=3` limit. When the DataMover crashes quickly due to transient issues (e.g. RabbitMQ `ACCESS_REFUSED` errors during credential rotation), the rapid restart cycle exhausts the limit and the unit enters `start-limit-hit` state (`systemctl status triliovault-datamover.service` shows `Result: start-limit-hit`). Once in that state, `systemctl start` immediately returns an error — the charm's own restart calls silently do nothing, leaving the DataMover permanently down even after the underlying issue is resolved. Setting `StartLimitIntervalSec=0` disables the limit entirely so the service always retries. If a compute node gets stuck in `start-limit-hit` on an older charm revision, recover with: `sudo systemctl reset-failed triliovault-datamover.service && sudo systemctl reset-failed triliovault-dms.service`, then trigger a charm hook re-run.

### Nova user UID normalisation (data plane)
WLM containers (trilio-wlm-k8s, trilio-dms-k8s) run as `nova` UID 42436. DataMover on compute nodes also runs as `nova` and writes to the same NFS backup target, so both sides must use the same UID.

Sunbeam compute nodes run nova-compute inside the `openstack-hypervisor` snap as **root** — no host-level `nova` user exists. The charm creates one at UID 42436. If a legacy `nova` user exists (e.g. from a `nova-common` deb install at UID 116), the charm:
- `change-nova-user-id=false` (default): sets `BlockedStatus` with an error message
- `change-nova-user-id=true`: runs `groupmod`/`usermod` to move nova to UID/GID 42436 and re-owns Trilio directories

**Before `usermod`**: stop Trilio services and then run `systemctl kill --kill-who=all --signal=SIGKILL <service>` for both `triliovault-datamover` and `triliovault-dms`. The `kill --kill-who=all` is required because `s3vaultfuse` (spawned by trilio-dms-server as a child process) can outlive `systemctl stop` and block `usermod` with "user is currently used by process".

The `_ensure_nova_user()` check runs at the **top of `_configure()`** (not only in `_on_install()`). This means every event path — install, config-changed, relation-changed — enforces the check. Setting `change-nova-user-id=true` via `juju config` fires a `config-changed` event which triggers the UID update automatically.

**`nova.conf` re-chown on stale ownership**: `_sync_nova_conf()` normally returns early (no file write) when nova.conf content has not changed. After a nova GID change, this leaves `/etc/triliovault-datamover/nova.conf` with the old GID — unreadable by the `nova` user. Fix: always call `shutil.chown(NOVA_CONF_COPY, user="root", group="nova")` even on the early-return path so ownership is corrected after every `_configure()` call.

### nova.conf and CA cert handling (data plane)
The `openstack-hypervisor` snap's nova.conf is at `/var/snap/openstack-hypervisor/common/etc/nova/nova.conf` (root:root 640 — unreadable by the nova user). The charm copies it to `/etc/triliovault-datamover/nova.conf` (root:nova 640).

**Only one line is patched in the copy**: the `cafile=` line in `[keystone_authtoken]` (and any other section) that references a snap-internal path (`/var/snap/openstack-hypervisor/.../receive-ca-bundle.pem`, also root:root 640). It is rewritten to `/etc/triliovault-datamover/ca-bundle.pem`.

The CA cert at that path comes from the **`receive-ca-cert` Juju relation** — NOT copied from the snap. `_write_ca_cert()` reads the CA from the relation databag and writes it to:
1. `/etc/triliovault-datamover/ca-bundle.pem` (root:nova 640) — for tvault-contego's direct use via `cafile=`
2. `/usr/local/share/ca-certificates/trilio-ca.crt` + `update-ca-certificates` — system trust store for all other tools

**Ordering in `_configure()`**: `_write_ca_cert()` must run before `_sync_nova_conf()` so the CA file exists before nova.conf references it.

If the `receive-ca-cert` relation has no data yet, the `cafile=` line is stripped entirely so keystoneauth1 falls back to the world-readable system CA trust store.

### DMS client conf (data plane)
`/etc/triliovault-dms/client.conf` is written by the `trilio-data-mover` charm when `wlm-db-url` config is set. It contains WLM DB URL, same RabbitMQ credentials as DMS server, and `node_id = socket.getfqdn()`.

### DMS client conf (control plane — WLM) — vhost and node_id are NOT WLM's own
`trilio-wlm-k8s` also writes `/etc/triliovault-dms/client.conf` (`_write_dms_client_config`) for the `trilio_dms` Python client library's mount/unmount RPC calls (used by `workloadmgr trust-create`'s post-trust settings upload and by `backup-target-create`'s mount validation). Two easy-to-get-wrong fields:
- **`rabbitmq_url`**: must be the **`dmapi`** RabbitMQ vhost, not WLM's own `wlm` vhost — the DMS server's `trilio_dms` topic exchange lives in the `dmapi` vhost (`trilio-dms-k8s`'s own `amqp` relation explicitly requests `username=dmapi, vhost=dmapi`, "since they communicate via shared RabbitMQ queues"). WLM needs a **second, separate** `amqp`-interface relation (`amqp-dms`, wired to `rabbitmq:amqp` in `trilio-ctlplane-bundle.yaml`) requesting the same `dmapi`/`dmapi` username/vhost — this is idempotent, rabbitmq-k8s just returns the already-provisioned user. Using WLM's own `wlm` vhost silently "succeeds" (kombu auto-declares a private `trilio_dms` exchange in the wrong vhost) and then hangs for exactly `request_timeout` (60s) with no error, because nothing is listening on that phantom exchange.
- **`node_id`**: `trilio_dms.client.DMSClient` defaults a request's target `host` to the **client's own** `node_id` when not explicitly given. This field must be the **DMS server's** identity, not WLM's — get it wrong and WLM publishes to `dms.<wrong-name>`, a routing key nothing is bound to, again a silent 60s timeout. `trilio-dms-k8s` is a `scale: 1` singleton (like wlm-cron) with a deterministic k8s pod name (`<app-name>-0`), so WLM hardcodes `DMS_SERVER_NODE_ID = "trilio-dms-k8s-0"` as a documented constant — there's no relation currently exposing DMS's own resolved node_id (which itself falls back to this exact same value when `K8S_NODE_NAME` downward-api injection is unavailable — confirm both sides agree via `cat /etc/triliovault-dms/client.conf` on WLM and `grep node_id /etc/triliovault-dms/server.conf` on DMS if debugging).

Kolla-ansible sidesteps both issues entirely: WLM and DMS share ONE RabbitMQ vhost/user (`openstack`, kolla's global RPC convention) and are co-located on the same host (`node_id = {{ ansible_fqdn }}` on both sides) — so there's nothing to compare against in that reference implementation; the mismatch is Sunbeam-specific (per-service vhosts + separate pods).

### Cloud admin trust prerequisites (`workloadmgr trust-create --is_cloud_trust True <role>`)
Required once after WLM reaches `active` (`juju run trilio-wlm-k8s/leader create-cloud-admin-trust password=<pw>`, or the raw CLI). Three distinct failure modes if any of these is missing — each surfaces as a different, unhelpful error:
1. **`Invalid input for field 'identity/password/user/password': None is not of type 'string'`** — `workloadmgr/common/context.py`'s `trusts_auth_plugin` builds its Keystone auth plugin from `cfg.CONF.keystone_authtoken.admin_user`/`admin_password` (legacy keystonemiddleware v2 aliases), which the charm's `[keystone_authtoken]` template never wrote (only the modern `username`/`password`). Fixed by adding `admin_user`/`admin_password`/`admin_tenant_name` to the template (matches kolla-ansible's and the old `charm-trilio-wlm`'s `[keystone_authtoken]`).
2. **`Expecting to find domain in user`** — the same code path needs `keystone_authtoken.user_domain_id` (an actual Keystone domain **ID**, not name) for the WLM service user's domain. It defaults to the literal string `"default"` unless overridden — but Sunbeam's `service_domain` is a real, separately-created domain with its own UUID, not Keystone's built-in `default` domain. Fixed by reading `service-domain-id` from the `identity-service` relation databag (keystone-k8s already provides it; the charm just wasn't consuming it) and writing it as `user_domain_id`.
3. **`No cloud admin trust found. Please recreate using CLI`** (from `backup-target-create`, even right after a successful `trust-create`) — `workloadmgr/compute/nova.py`'s `_get_trusts('cloud_admin', CONF.cloud_admin_project_id)` looks up the trust by the charm config options `cloud-admin-user-id`/`cloud-admin-project-id`. **Fixed as of 2026-07-25: the charm now auto-populates both from the identity-service relation's own `admin-user-id`/`admin-project-id` fields** (keystone-k8s already publishes these — matching how the older reactive `charm-trilio-wlm` sourced the same two fields via `identity_service.get('admin_user_id')`/`'admin_project_id'`), so this is no longer a manual step on a fresh deployment. Charm config still overrides this if explicitly set. See `_ensure_service_user_default_project`-adjacent code in `charm.py` for the pattern (it lives right after `_register_keystone_service`).
4. Separately, the admin user used for `trust-create --is_cloud_trust True admin` must actually hold the `admin` role at **system scope** (`openstack role add --user admin --user-domain admin_domain --system all admin`) — a fresh Sunbeam `admin` user only has `admin` on its own project + domain, not system-wide, and the trust silently succeeds for a user that then can't act as a true cross-domain cloud admin.

**Root-caused and fixed as of 2026-07-25 — WLM service account needs its own Keystone `default_project_id` set, or every Nova/Cinder/Glance call gets an empty service catalog.** `workload-snapshot` used to fail immediately with `Failed creating workload snapshot: The service catalog is empty.` This was initially misdiagnosed as Keystone rejecting trust-scoped-token reuse in `nova_micro_client()` (that rejection IS real Keystone behavior, confirmed independently, but turned out not to be the code path actually hit — the password-auth branch is what runs). The **actual** cause, found by direct comparison against a working charm-trilio-wlm reference deployment: `nova_micro_client()`/`_get_tenant_context()` in `workloadmgr/compute/nova.py` never pass an explicit project scope (`project_id`/`project_name`/`tenant_id`) on ANY client session they build — they rely entirely on Keystone auto-scoping to the authenticating user's own `default_project_id` when none is given, and an unscoped token has zero catalog entries by Keystone's own spec. keystone-k8s creates the WLM service account via the identity-service relation but never sets `default_project_id` on it, unlike the working reference deployment's equivalent account (which has it set to its own "services" project). **Fix (now in charm code, self-healing):** the charm sets its own service account's `default_project_id` (to its own "services" project, which it already holds a role on) as part of every `_configure()` run — see `_ensure_service_user_default_project` in `charm.py`, called right after `_register_keystone_service`. Verified: a real full snapshot progressed past workflow initialization into actual execution for the first time after this fix (previously always failed within seconds). The underlying WLM code gap (never setting explicit project scope) is still worth a product-level fix and would recur on any other deployment whose WLM service account happens to lack a usable default project — this charm-side fix is a robust workaround, not a fix to WLM itself.

**Next blocker after both of the above are fixed — TVAULT-7515 (open, unresolved as of 2026-07-25):** snapshot execution now reaches the freeze/snapshot step, then fails with `novaclient.exceptions.ClientException: Unknown Error (HTTP 502)` from contego's `vast_instance` Nova server-action call — fatal to the whole snapshot. The same 502 also occurs on contego's `vast_thaw` action from the identical `contego_python_novaclient_ext` code path, but that failure is swallowed by the calling workflow code and doesn't itself abort the snapshot — meaning the bug isn't specific to one action, it affects every call this client extension makes. **novaclient-version-mismatch theory tested live and disproven**: `contego_python_novaclient_ext` builds requests using legacy `HTTPClient` attributes (`management_url`, `service_catalog`, `get_service_url()`, `auth_token`, `projectid`) that don't exist on novaclient's modern `SessionClient`; Sunbeam runs a newer novaclient than the working reference deployment, so a version mismatch looked plausible. Rebuilt the WLM image pinned to the reference env's exact novaclient version (`pip3 install python-novaclient==17.6.0` — apt-level pinning fails because `python3-openstackclient` hard-requires `>=2:18.1.0`), deployed it live, retested — **identical 502 still occurred**. Confirmed `SessionClient` lacks those legacy attributes in both versions at the source level, and `novaclient.client._construct_http_client()` always builds `SessionClient` regardless of version/auth method — the version difference was a red herring. Also confirmed via simultaneous log capture across wlm-api/wlm-workloads/dm-api that **dm-api is never contacted during a failed attempt** — contego's calls go directly WLM→Nova-API, never through dm-api. And confirmed nova-api itself and the ingress path are NOT the problem: reproducing the same action call directly (bypassing `contego_python_novaclient_ext`) gets clean 404/400 responses, not a 502. `python3-tvault-contego` and the WLM-side client extension are confirmed byte-for-byte identical between Sunbeam and the reference deployment. Genuinely not yet root-caused — the actual differentiator is unknown. This is the current active blocker for finishing NFS/S3 backup validation.

### FUSE device access for s3vaultfuse (control plane k8s charms only)
`s3vaultfuse` (S3 backup targets) needs `/dev/fuse` + a privileged security context. Data-plane machine charms (`trilio-data-mover-sunbeam`, and the legacy `charm-trilio-data-mover`) get this for free — they install `fuse`/`libfuse2` on a real host, which already has `/dev/fuse`. The k8s control-plane charms (`trilio-wlm-k8s`, `trilio-dms-k8s`) do **not** — and worse, **sidecar k8s charms have no `charmcraft.yaml` field for `securityContext`/host-device access at all** (only `resource` and `mounts` under `containers:`). Both charms self-patch their own StatefulSet at runtime via `lightkube` (`_patch_fuse_device()`, using a strategic-merge patch adding `securityContext.privileged: true` + a `dev-fuse` hostPath volume/mount) — this requires `trust: true` on the application (already set in `trilio-ctlplane-bundle.yaml`, which grants the operator service account a namespace-scoped `apiGroups: ["*"], resources: ["*"], verbs: ["*"]` Role — no extra RBAC needed). The patch triggers one StatefulSet-driven pod restart to take effect; `_configure()` calls it idempotently (checks for the existing `securityContext.privileged` + `dev-fuse` volumeMount before patching) so it's a no-op on every subsequent hook run.

### `python3-s3-fuse-plugin` boto3/botocore pin (docker/trilio-dms image)
The Trilio APT package `python3-s3-fuse-plugin` (6.2.1.1) declares `boto3==1.35.12`/`botocore==1.35.12` in its own dependency metadata, but as installed in the `trilio-dms-canonical` image, `boto3 1.20.34`/`botocore 1.23.34` end up on disk instead — old enough that `botocore.httpsession` fails to import against the image's `urllib3` 2.x (`ImportError: cannot import name 'DEFAULT_CIPHERS' from 'urllib3.util.ssl_'`), crashing `s3vaultfuse` immediately on every mount attempt. Fixed with an explicit `pip3 install boto3==1.35.12 botocore==1.35.12` in the Dockerfile right after the apt install — pin to what the package itself already requires, don't chase urllib3 downgrades instead.

### `docker/trilio-dms/trilio.list` is a template, not a literal apt source
It ships as the literal string `{DEB_REPO_URL}` — `devops-build-publish.sh` substitutes the real APT repo line into it (`sed -i "s|{DEB_REPO_URL}|${APT_REPO_URL}|g"`) before `docker build`. Building directly (as the existing dev-build note above already recommends for dev tags) will fail apt with `Malformed line 1 in source list` unless you substitute this placeholder yourself first — and restore it afterward so the checked-in file stays a template.

### Root-user architecture (current, as of 2026-07-24) — supersedes nova-user for WLM/DMS/datamover
After validating the nova-user approach (sections above), an experiment ran WLM, DMS, and datamover entirely as **root** instead of the dedicated `nova` user, specifically to remove the libvirt UID-resolution relay workaround (the "main blocker" described in the historical notes above) and the ownership/permission workarounds it needed. The experiment succeeded and is now the standing architecture:
- `trilio-wlm-k8s` and `trilio-dms-k8s` Pebble layers no longer set `user`/`group` on their services — reverted to Pebble's default (root).
- `trilio-data-mover-sunbeam`'s `DATAMOVER_SYSTEMD_UNIT`/`DMS_SYSTEMD_UNIT` now use `User=root`/`Group=root` instead of `nova`/`nova`.
- Removed as no-longer-needed: the qemu+ext:// libvirt-connect relay wrapper and its sudoers entry (root always resolves in libvirtd's confined passwd — no relay needed), the `usermod -aG disk/kvm/root nova` group-membership grants, and the ownership/chmod calls on the Nova instances/snapshots directories.
- **Not part of this change**: `trilio-dm-api-k8s` keeps its own distinct `dmapi` Pebble user (uid 63630) — dm-api was never in scope for the nova-vs-root question.
- **dm-api log directory ownership must self-heal every `_configure()` run** (fixed 2026-07-25): `/var/log/triliovault/triliovault-datamover-api.log` was found root-owned at runtime even though the Dockerfile chowns the directory to `dmapi:dmapi` at build time — since the Pebble service always runs as `dmapi`, a root-owned log file makes oslo_log's `FileHandler` fail with `PermissionError` on every startup, so `dmapi-api` exits immediately and Pebble respawns it in a silent ~30s crash loop (silent because it dies before it can log anywhere but stdout — the Juju unit itself still shows `active`/`idle` with no visible error). `_configure()` now runs `chown -R dmapi:dmapi` on `LOG_DIR` (`_ensure_log_permissions`) before applying the Pebble layer, on every hook — don't rely on the Docker build-time chown alone, since any runtime-created file trivially bypasses it.
- Tradeoff: this diverges from kolla/RHOSP convention (UID-consistent `nova` user across compute-side and control-plane-side components). Intentional for Sunbeam specifically, not a recommendation for other platforms.
- A rollback snapshot documenting the pre-experiment nova-user charm revisions/container tags was written before this change — ask if you need to find/recreate it; the nova-user code paths themselves are described in the historical sections above and are fully removed from the current charm source (git history has the diff if a rollback is ever needed).

### Ceph-client relation for datamover (contego's own RBD credentials)
`trilio-data-mover-sunbeam` has its own `ceph` relation (interface `ceph-client`) to the Ceph cluster application (microceph on Sunbeam), so contego gets a dedicated Ceph client key for direct `rbd` CLI usage against Ceph-backed Cinder volumes — not needed for Nova's own attach flow, only for contego's own rbd reads. Two library/behavior gotchas:
- **`interface_ceph_client`'s `_ops_equal()` bug**: it only compares a fixed key list (`replicas`, `name`, `op`, `pg_num`, `group-permission`, `object-prefix-permissions`) when deciding if a new broker request duplicates a prior one — `client`/`permissions` are NOT in that list. Sending a first broad request then a second, narrower `set-key-permissions` request gets silently discarded as a "duplicate". **Workaround implemented**: never send two differing requests — discover the exact pool name(s) and final capability string up front (via a direct libvirt domain scan, which works even before any Ceph credentials exist) and send exactly ONE `set-key-permissions` request ever, already scoped to the final permission needed.
- **Ceph client name is NOT whatever you request**: ceph-mon/microceph's broker auto-provisions a client key named after the consuming application's Juju **application name**, regardless of what `client=` string the charm's own broker request specifies. `_ceph_client_name` must be a property that returns `self.app.name` dynamically (not a hardcoded string) to stay consistent with whatever key the broker actually created.
- If a configured Cinder/Nova Ceph pool doesn't actually exist, skip it rather than erroring — don't assume all conventionally-named pools are present.

### Barbican (Key Manager) for DMS secret storage
Sunbeam deploys Barbican as part of its core control plane — it is always available, no extra steps needed. Use it for storing DMS secret payloads (`backup-target-create --secret-ref`). The earlier approach of deploying a custom `secret-server` k8s pod as a Barbican substitute was wrong and has been removed.

Key gotchas:
- **Barbican `payload_content_type` must be `text/plain`** — Barbican rejects `application/json`. The DMS payload is JSON text stored as an opaque text secret; this is correct and DMS reads it fine.
- **Barbican endpoint is not reachable via k8s ClusterIP from compute nodes** — Compute nodes (172.26.2.5, .6) cannot reach MicroK8s ClusterIPs. Always use the public endpoint from the Keystone service catalog (`key-manager` service, `public` interface), which routes via the floating IP/ingress and IS reachable from compute nodes.
- **Build server may lack the barbicanclient openstack CLI plugin** — create secrets via the Barbican REST API from inside the WLM pod instead (see `sunbeam-canonical/test/01_create_backup_targets.sh`).
- **Sunbeam admin user is in `admin_domain` domain** (not `Default`) — Keystone auth must use `user_domain_name=admin_domain`, `project_domain_name=admin_domain`.

### DMS mounts on-demand (event-driven), not proactively at startup
The DMS server does not mount all registered backup targets when it starts — it waits for a job over its RabbitMQ RPC queue (`dms.<node-id>`) to trigger a mount. Restarting the `trilio-dms-server` Pebble service does **not** by itself remount anything; it only appears to "fix" a stale mount if a mount request happens to arrive shortly after. Corollary: WLM's `workload-create`/`workload-snapshot` flows themselves are what trigger the on-demand mount via DMS RPC — if the mount is genuinely absent or stale, the first request after a restart is what actually re-establishes it, not the restart alone.

### Recurring NFS backup-target staleness (host-level, not just container-level)
The NFS client mount to a backup target (e.g. `192.168.0.51:/home/rhosp`) periodically goes stale — the mount entry is present in `/proc/mounts` but any filesystem operation against it (even `ls`) hangs indefinitely. This has recurred multiple times across different testing sessions and is a property of this specific NFS backend, not something introduced by charm changes. Fix: a **lazy unmount** (`umount -l`) followed by a fresh mount attempt (triggered by the next DMS job, or by restarting `trilio-dms-server` right before retrying) clears it. Two things that are easy to get wrong when debugging this:
1. **DMS mounts NFS on the actual Kubernetes node's host filesystem, not just inside its own container.** `trilio-dms-k8s`'s `vault-mounts` volume mount uses `mountPropagation: Bidirectional` against a shared `hostPath` (`/var/lib/trilio/vault-mounts` — same path on both WLM's and DMS's pod specs), so the real mount lives on the k8s node (`kubectl get pods -o wide` to find which node) and a stale/hung mount must be unmounted **there** (SSH to that node, not just `kubectl exec`), not just inside the DMS container's own view of it.
2. `trilio-wlm-k8s`'s own `vault-mounts` volume mount uses `mountPropagation: HostToContainer` (receive-only) against the same hostPath — WLM's pod does NOT itself hold or trigger the mount, it only observes whatever DMS has mounted on the shared host path. Checking `/var/triliovault-mounts/...` inside the WLM pod and seeing an empty directory does not necessarily mean "not mounted" — check DMS's pod (or the host) for the authoritative mount state.

### Windows-checkout file sync to the Linux build server — don't `cat | ssh cat >` raw
This repo has `core.autocrlf=true`; every file in a Windows working tree has CRLF line endings, and that's fine for git itself (autocrlf normalizes to LF transparently on commit/push). But copying a file's raw working-tree bytes straight to the Linux build server (`cat file | ssh ... "cat > file"`, used to sync a fix before `charmcraft pack`/`docker build`) preserves the CRLF, and CRLF in a shebang line breaks it silently and confusingly: `/usr/bin/env: 'python3\r': No such file or directory`, surfacing as `upgrade-charm` hook failing with exit 127 well after the charm looked like it packed and released fine. Either `sed -i 's/\r$//'` the affected files on the server right after copying (before packing), or sync via git (commit + push + pull on the server) so autocrlf handles it.

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

### Bundle reference entries for pre-existing apps MUST pin revision + scale — this caused a real outage
Both `trilio-ctlplane-bundle.yaml` and `trilio-dataplane-bundle.yaml` declare "reference entries" for Sunbeam core applications they relate to but don't own (mysql, rabbitmq, keystone, traefik, traefik-public, openstack-hypervisor, microceph) — Juju requires every relation endpoint in a bundle to be declared, even for apps the bundle isn't meant to manage. **On 2026-07-24, omitting `revision:` and `scale:` on these entries caused `juju deploy` to treat them as a desired-state change**: Juju force-scaled all five ctlplane reference apps toward 0 units and force-upgraded their charm revisions to whatever the channel currently resolved to, cascading into a near-total control-plane outage (nova, neutron, cinder, glance, horizon, barbican, placement all went blocked/error, plus ~35 mysql-router subordinate units). Recovery took about 20 minutes of `juju resolved` cycling and waiting for in-flight charm upgrades to complete a pod cycle; no data was actually lost (underlying pods/PVCs were never destroyed — confirmed via `kubectl get pods` showing continuous multi-week uptime through the incident), but it was a serious live-outage scare.

**Rule going forward: before deploying either bundle, always check `juju status` for the CURRENT revision and unit count of every reference-entry app, and make sure the bundle's `revision:`/`scale:` fields match exactly.** Both bundle files now have these pinned and carry an inline caution comment — never remove or leave them implicit again. `juju deploy ./bundle.yaml --dry-run` is a good sanity check before a real deploy: it should show ONLY the Trilio apps being deployed/related, never "scale X to N units" or "upgrade charm" for any of the reference-entry apps.

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

Publish channel: **`6.2/candidate`**

Build and publish workflow:
```bash
# On build server — pack each charm
cd sunbeam-canonical/charms/<charm-dir>
charmcraft pack

# Upload and release — always use CHARMCRAFT_AUTH from ~/creds.txt on the build server
CHARMCRAFT_AUTH=$(cat ~/creds.txt) charmcraft upload <charm>.charm --name <charm-name>
# Note the revision number from upload output, then:
charmcraft release <charm-name> --revision <N> --channel 6.2/candidate
```

> **Note:** `charmcraft login` requires a browser on first use. Run `charmcraft login --export creds.txt` locally, transfer `creds.txt` to the server, then `export CHARMCRAFT_AUTH=$(cat creds.txt)` before building.

#### `build-packages: [git]` required in charmcraft.yaml
charmcraft's LXD build container does not include `git` by default. Any charm whose `requirements.txt` has a `git+https://` dependency will fail during `charmcraft pack` with:
```
ERROR: Error [Errno 2] No such file or directory: 'git' while executing command git version
```
Fix: add `build-packages: [git]` under the `parts.charm` section of `charmcraft.yaml`. This is already in `trilio-data-mover-sunbeam/charmcraft.yaml` — every charm with git-URL pip deps needs it.

#### LXD zombie container blocks subsequent `charmcraft pack`
If a previous `charmcraft pack` invocation was killed or backgrounded and left behind a stopped LXD container, the next pack attempt fails with:
```
Error: The device already exists
```
Check for stopped containers: `lxc list | grep charmcraft`. If the container is `STOPPED` (not `RUNNING`), wait a moment and retry — charmcraft will reuse or clean it up. If it is `RUNNING` from a background job, wait for it to finish before starting a new pack.

#### Deploying bundles — use `./` path and `--trust`
`juju deploy` does NOT accept an absolute path outside the current directory for bundle YAML files:
- **Wrong**: `juju deploy /tmp/trilio-ctlplane-bundle.yaml` → "no charm was found"
- **Correct**: copy the bundle to the working directory and deploy with `./`: `juju deploy ./trilio-ctlplane-bundle.yaml`

Both control-plane bundles require `--trust` because the WLM and DMAPI charms patch their own StatefulSets at runtime via the Kubernetes API (FUSE device access, shared vault-mounts volume):
```bash
juju switch openstack
juju deploy ./trilio-ctlplane-bundle.yaml --trust

juju switch openstack-machines
juju deploy ./trilio-dataplane-bundle.yaml
# (data plane bundle does NOT need --trust)
```

Also strip CRLF from bundle files copied from the Windows working tree before deploying — see the "Windows-checkout file sync" note above.

---

## Testing

### Fresh reinstall procedure (clean slate)
When a fresh reinstall is needed (e.g. to pick up new charm revisions or reset corrupt state), follow this order:

```bash
# 1. Remove control plane applications (--destroy-storage drops MySQL databases too)
juju switch openstack
juju remove-application trilio-wlm-k8s trilio-dm-api-k8s --destroy-storage

# Wait until pods are fully terminated
kubectl get pods -n openstack | grep trilio   # expect: no output

# 2. Remove data plane
juju switch openstack-machines
juju remove-application trilio-data-mover

# Wait until subordinate units are gone
juju status trilio-data-mover   # expect: "not found"

# 3. Verify MySQL databases are gone (--destroy-storage above should handle this,
#    but verify if re-deploy gets a "database already exists" error)
kubectl exec -n openstack mysql-k8s-0 -c mysql -- \
  mysql -u root -p$(kubectl get secret -n openstack mysql-k8s-app -o jsonpath='{.data.root-password}' | base64 -d) \
  -e "SHOW DATABASES;" | grep -E 'workloadmgr|dmapi'
# If databases still exist, drop them:
# DROP DATABASE workloadmgr; DROP DATABASE dmapi;

# 4. Deploy fresh
juju switch openstack
juju deploy ./trilio-ctlplane-bundle.yaml --trust

juju switch openstack-machines
juju deploy ./trilio-dataplane-bundle.yaml

# 5. Wait for active, then attach license and create trust
juju switch openstack
juju wait-for application trilio-wlm-k8s --query='status=="active"' --timeout=15m
juju attach-resource trilio-wlm-k8s license=<path-to-license>
juju run trilio-wlm-k8s/leader create-cloud-admin-trust password=<admin-password>
```

### workloadmgr test scope — admin credentials required
`workloadmgr workload-list` and `snapshot-list` are scoped to the authenticated user's project. If workloads were created using admin credentials (project=`admin`), the service account credentials (project=`services`) will return an empty list. Always use the same credentials (project scope) that were used to create the workload:

```bash
# Inside the WLM pod — use admin project scope, not service account
kubectl exec -n openstack trilio-wlm-k8s-0 -c trilio-wlm -- \
  setsid workloadmgr \
    --os-auth-url http://<keystone-clusterip>:5000/v3 \
    --os-username admin \
    --os-password <admin-password> \
    --os-project-name admin \
    --os-user-domain-name admin_domain \
    --os-project-domain-name admin_domain \
    workload-list
```

The `setsid` prefix is required — see the "workloadmgr CLI in Pebble exec" section above.

### Snapshot verification test flow
After fresh install and license/trust setup:
1. Create backup target (NFS or S3) via the test script: `sunbeam-canonical/test/01_create_backup_targets.sh`
2. Create a test workload (one VM): run `workloadmgr workload-create` from inside the WLM pod
3. Trigger a snapshot: `workloadmgr snapshot-create <workload-id>`
4. Poll status: `workloadmgr snapshot-show <snapshot-id>` until `available` (success) or `error`
5. On error: check WLM logs (`kubectl logs -n openstack trilio-wlm-k8s-0 -c trilio-wlm`) and DataMover logs on compute nodes (`journalctl -u triliovault-datamover`)
