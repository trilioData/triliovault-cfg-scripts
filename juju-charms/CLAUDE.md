# Juju Charms — Canonical OpenStack Deployment

## Overview
This directory contains the source code for all four TrilioVault (T4O) Juju charms used to deploy T4O on Canonical OpenStack.
Each charm subdirectory is a full copy of the corresponding upstream GitHub repo (trilioData/charm-trilio-*), synced from the relevant branch.

Charms are published to Charmhub and deployed via `juju deploy`. `charmcraft pack`, `charmcraft upload`, and `charmcraft release` are run from within each charm's subdirectory — they do not depend on the git repo structure.

**T4O Install Guide on Canonical OpenStack**: https://docs.trilio.io/openstack/deployment/installing-on-canonical

## Charm Directory Map

| Directory | T4O Component | Deployed On |
|-----------|--------------|-------------|
| `charm-trilio-wlm/` | WorkloadManager (wlm-api, wlm-workloads, wlm-cron, wlm-scheduler) | Control plane nodes |
| `charm-trilio-dm-api/` | DataMover API (dmapi) | Control plane nodes |
| `charm-trilio-data-mover/` | DataMover | All nova-compute nodes (subordinate) |
| `charm-trilio-horizon-plugin/` | Horizon UI plugin | Horizon nodes (subordinate) |

## Supported OpenStack Releases
Yoga, Antelope (2023.1), Bobcat (2023.2), Caracal (2024.1)

## Upstream Repositories
| Charm | Upstream | Fork |
|-------|----------|------|
| charm-trilio-wlm | https://github.com/trilioData/charm-trilio-wlm | https://github.com/shyam-biradar/charm-trilio-wlm |
| charm-trilio-data-mover | https://github.com/trilioData/charm-trilio-data-mover | https://github.com/shyam-biradar/charm-trilio-data-mover |
| charm-trilio-dm-api | https://github.com/trilioData/charm-trilio-dm-api | https://github.com/shyam-biradar/charm-trilio-dm-api |
| charm-trilio-horizon-plugin | https://github.com/trilioData/charm-trilio-horizon-plugin | https://github.com/shyam-biradar/charm-trilio-horizon-plugin |

---

## Charm Structure (same layout for all four)

```
charm-trilio-<name>/
├── charmcraft.yaml          # Build config — defines bases (Ubuntu versions), reactive plugin, source: src/
├── metadata.yaml            # Top-level charm metadata (mirrors src/metadata.yaml)
├── requirements.txt         # Python deps for the outer build tooling
├── tox.ini                  # Tox config for linting and unit tests
├── unit_tests/              # Python unit tests (pytest)
│   ├── __init__.py
│   ├── test_<charm>_handlers.py
│   └── test_lib_charm_openstack_<charm>.py
└── src/                     # Actual charm source (charmcraft builds from here)
    ├── metadata.yaml        # Charm name, series, interfaces, resources
    ├── layer.yaml           # Reactive layer dependencies (layer:openstack, interfaces)
    ├── config.yaml          # Charm configuration options exposed to juju operators
    ├── actions.yaml         # Juju actions (runnable by operator)
    ├── wheelhouse.txt       # Pinned pip packages baked into the charm
    ├── wheelhouse/          # Pre-downloaded .whl files (offline builds)
    ├── reactive/
    │   └── <charm>_handlers.py   # Reactive state handlers — main charm logic entry point
    ├── lib/charm/openstack/
    │   └── <charm>.py            # charms_openstack class — service config, install, render
    ├── templates/           # Jinja2 config file templates rendered onto the unit
    │   ├── triliovault-<component>.conf
    │   └── <component>_logging.conf
    ├── actions/             # Action scripts (symlinked to actions.py)
    │   └── actions.py
    ├── files/               # Static files copied to the unit
    └── tests/               # Integration test bundles (Zaza / Amulet)
        ├── tests.yaml
        └── bundles/
            └── <os>-<release>-<charm_ver>.yaml
```

## Technology Stack
- **charms_openstack**: Python framework for OpenStack charms (provides base classes for service config, package install, relation handling)
- **charms.reactive**: Decorator-based reactive pattern — handlers fire when specific states are set/cleared
- **charmcraft**: Build (`charmcraft pack`) and publish (`charmcraft upload`, `charmcraft release`) tool
- **Jinja2**: Config file templating (same syntax as Ansible/Kolla)
- **Zaza**: Integration test framework (test bundles in `src/tests/bundles/`)
- **pytest**: Unit test framework (`unit_tests/`)

## Key Conventions

### Reactive Pattern
Code flow: operator sets config → reactive states change → handler functions fire → charm calls lib methods.
- `src/reactive/<charm>_handlers.py` — `@reactive.when(...)` / `@reactive.when_not(...)` decorated functions
- `src/lib/charm/openstack/<charm>.py` — `TrilioCharm` subclass with `packages`, `services`, `restart_map`, `required_relations`, config rendering

### Adding a New Config Option
1. Add to `src/config.yaml` (with type, default, description)
2. Add to the relevant template in `src/templates/`
3. The `charms_openstack` base class auto-renders config options into templates via `render_configs()`

### Adding a New Relation
1. Add the interface to `src/layer.yaml` under `includes:`
2. Add the relation to `src/metadata.yaml` under `requires:` or `provides:`
3. Add handler(s) in `src/reactive/<charm>_handlers.py` using `@reactive.when('relation.available')`

### Adding a New Action
1. Declare it in `src/actions.yaml`
2. Implement in `src/actions/actions.py`
3. Add a dispatch stub at `src/actions/<action-name>` (see convention below — do **not** hand-copy `actions.py`)

### Convention: action entrypoint files are thin dispatch stubs, not copies
Juju executes `src/actions/<action-name>` directly, and `actions.py`'s `main()` decides which action to run from `os.path.basename(sys.argv[0])` — i.e. from the *name of the invoked file*, not from which file the code physically lives in. Each `src/actions/<action-name>` file (across `charm-trilio-wlm`, `charm-trilio-dm-api`, `charm-trilio-data-mover`) is therefore a tiny stub:
```python
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from actions import main
if __name__ == "__main__":
    sys.exit(main(sys.argv))
```
This never needs to change when `actions.py` changes — it just delegates. **This replaced an earlier convention** (hand-copying the entire contents of `actions.py` into every action-name file) that had already caused a real bug: `charm-trilio-wlm/src/actions/unmount-old-backup-targets` was missing an entire fix (the `tvault-object-store-*.service` stop/disable logic from commit `9c135ce27`) that had been merged into `actions.py` weeks earlier, because nobody re-copied it (found while fixing TVAULT-7523, corrected while fixing TVAULT-7521/7522/7523). Symlinks were considered instead but avoided for Windows-checkout portability (this repo is also worked on from Windows dev machines) — the stub achieves the same "single source of truth" property without needing filesystem symlink support.

### Gotcha: `update-trilio` (and any action) never fires reactive hooks
Juju actions in `charms.reactive`-based charms are plain Python entrypoints — they do **not** go through the reactive hook-dispatch loop (`charms.reactive.main()`). So calling `run_trilio_upgrade()` from an action only performs the package upgrade; hook-gated handlers like `render_config()` (re-renders `rabbitmq_url` etc. into config) and `init_db()` (`db_sync()`, the alembic migration) do **not** run as a side effect, even though they normally follow a package change on a real hook. Any action that upgrades packages must explicitly call the equivalent render/migration functions itself afterward (see `render_wlm_and_dms_configs()` in `charm-trilio-wlm`, `render_dmapi_and_dms_configs()`/`render_dms_client_config()` in `charm-trilio-dm-api`, `render_dms_config_now()` in `charm-trilio-data-mover` — all added for TVAULT-7521/TVAULT-7522) rather than assuming a later hook will clean it up. `db_sync()` must run, and dependent services (wlm-api/workloads/scheduler/cron) must be stopped/restarted, in that order — restarting before migration completes crashes services on "Unknown column" errors (TVAULT-7522).

### Object-store service cleanup (6.1 → 6.2 upgrade)
6.2 removes static/`tvault-object-store.service`-based backup targets in favor of dynamic per-target mounts managed by `trilio-dms-server`. Leftover per-target systemd units follow the pattern `tvault-object-store-<BT_NAME>.service` (created dynamically by the DMS/s3vaultfuse runtime, not templated anywhere in this repo) and will auto-remount a target's FUSE/NFS mount if left running — `unmount_old_backup_targets()` must stop, disable, **and remove** the unit file (not just unmount), or the mount comes right back. See `unmount-old-backup-targets` action in `charm-trilio-wlm` and `charm-trilio-data-mover`.

### Canonical upgrade procedure reference
The authoritative 6.1→6.2.1 upgrade steps (including the required-but-easy-to-miss `juju add-relation trilio-data-mover:identity-service keystone:identity-service` step, new in 6.2) live in Confluence: "6.2.1 Install and Upgrade Step Changes for Canonical" (page 5051482119, space TVO). Check it before debugging any Canonical upgrade Jira — QA repro steps pasted into a Jira sometimes omit a step from this doc.

### Wheelhouse / Offline Dependencies
`src/wheelhouse.txt` lists pip packages to bundle. Pre-downloaded `.whl` files go in `src/wheelhouse/`.
Required when the charm target nodes have no internet access.

## Build and Publish Workflow

**Never install a locally-built `.charm` via `juju refresh --path=`/`juju deploy --path=` for verification.** Always `charmcraft upload` + `charmcraft release` to Charmhub first, then install/upgrade from the channel like a real deployment would. Local path installs skip the actual distribution path and can hide packaging issues.

**Release convention: always release to the `<TRACK>/candidate` channel** (e.g. `6.2/candidate`), never `edge` or straight to `stable`, even for a fix build being verified mid-session. `candidate` is the channel QA actively tests against, so releasing there is the expected way to get a fix in front of them — don't route around it into a side channel.

```bash
# From within the charm subdirectory:
cd juju-charms/charm-trilio-wlm

# Build
charmcraft pack

# Upload to Charmhub (produces a revision number)
charmcraft upload trilio-charmers-trilio-wlm_ubuntu-22.04-amd64.charm

# Release to the candidate channel for the target track
charmcraft release trilio-charmers-trilio-wlm --revision <N> --channel 6.2/candidate
```

Run the same commands from each charm's subdirectory independently.

### Gotcha: charmcraft snap channel must match this repo's `charmcraft.yaml` bases format
These charms' `charmcraft.yaml` use the legacy `bases: build-on/run-on` schema. The `latest/stable` charmcraft snap channel (4.x) requires the newer `platforms:` schema instead and fails immediately with a `BasesCharm` validation error. Use the `2.x/stable` channel (`sudo snap refresh charmcraft --channel=2.x/stable --classic`) to build these charms until/unless `charmcraft.yaml` is migrated to the new schema.

### Gotcha: build host must have LXD actually initialized, and must not be an OpenStack networking node
`charmcraft pack` needs a working LXD (or Multipass) backend. Don't assume any given Ubuntu box has this ready — check `lxc network list` shows a `MANAGED`/`CREATED` bridge before starting a build. Avoid building on a box that also runs live OpenStack networking (Neutron/OVN, e.g. a `nova-compute`/`ovn-chassis` unit) — `lxd init --auto` can fail there with a `dnsmasq: ... Address already in use` error regardless of which subnet LXD picks, because a system dnsmasq (Neutron DHCP) is likely already bound. Don't try to work around this by touching the box's networking — use a dedicated build host instead (see `env/setups.yaml` for known-good build boxes, e.g. the Sunbeam build server).

## Uninstall (for Upgrade/Fresh-Install Testing)

To tear down a Trilio deployment (e.g. before redeploying an older release to test an upgrade path, or before a clean fresh-install test), remove all four principal charms **and their mysql-router subordinates explicitly** in one command — don't rely on subordinates being auto-removed, they can be left behind as orphaned applications:

```bash
juju remove-application trilio-wlm trilio-dm-api trilio-data-mover trilio-horizon-plugin \
  trilio-dm-api-mysql-router trilio-wlm-mysql-router trilio-data-mover-mysql-router
```

Units commonly go into `error` state during removal (see gotcha below) — once they do, re-run the same command with `--force`:

```bash
juju remove-application trilio-wlm trilio-dm-api trilio-data-mover trilio-horizon-plugin \
  trilio-dm-api-mysql-router trilio-wlm-mysql-router trilio-data-mover-mysql-router --force
```

### Gotcha: removal commonly errors on unrelated interface-library bugs — safe to force through
Removing these charms frequently triggers hook failures unrelated to Trilio's own code, in shared/vendored interface libraries:
- `identity-service-relation-departed` can fail with `IndexError: list index out of range` in `hooks/relations/keystone/requires.py` (`self.relations[0]` accessed without checking the list is non-empty once the other side has already departed).
- On the `mysql-innodb-cluster` side, `db-router-relation-broken` can fail with `network-get --primary-address cluster` returning a non-zero exit — this can affect **all** `mysql-innodb-cluster` units, not just the one related to Trilio.

Both are teardown-only hook-script bugs, not data-loss or live-service issues — verify with `systemctl is-active mysql` on a `mysql-innodb-cluster` unit and check that unrelated apps sharing the same DB backend (e.g. `keystone`, `cinder`, `glance`) are still `active` before proceeding. Once confirmed, `juju resolved --no-retry <unit>` on each affected unit is safe.

### Gotcha: removing the Juju application does NOT clean the database
`juju remove-application` never drops the actual database in `mysql-innodb-cluster` — the schema and all data persist independently. If you're tearing down specifically to test an older release's fresh-install-then-upgrade path, this matters a lot: redeploying against a database that's already at the newer schema means `db_sync()`/alembic migration during the later upgrade step is a no-op, silently defeating the entire point of the test. Before redeploying, connect to a `mysql-innodb-cluster` unit (root credentials are in `leader-get` — look for the plain `mysql.passwd` key, and the per-service `mysql-<service>.passwd` keys) and explicitly drop the relevant databases and DB users:

```sql
DROP DATABASE IF EXISTS workloadmgr;
DROP DATABASE IF EXISTS dmapi;
DROP USER IF EXISTS 'workloadmgr'@'<unit-ip>';
DROP USER IF EXISTS 'dmapi'@'<unit-ip>';
```

Do this **before** the redeployed charms' `shared-db` relation completes (check `juju status` shows `'shared-db' incomplete`) — once it completes, the charm will just reconnect to whatever database already exists under that name instead of provisioning fresh.

## Syncing with Upstream
When upstream charm repos are updated, re-sync by running from the individual charm repos (in the workspace root):

```bash
cd <charm-repo>
git checkout dev-maint8/6.1        # or the relevant branch
git pull origin dev-maint8/6.1
git fetch upstream
git merge upstream/dev-maint8/6.1
```

Then re-copy the updated files into this directory (excluding `.git`).
