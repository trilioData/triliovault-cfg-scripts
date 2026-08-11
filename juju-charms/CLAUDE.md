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

### Gotcha: there is no `<application>/*` action wildcard, and subordinate units hide from naive loops
Verified against real binaries (Juju 2.9.60 and 3.6.27) — both reject `juju run-action 'trilio-data-mover/*' <action>` / `juju run 'nova/*' <action>` with `ERROR invalid unit or action name`. Only a concrete unit ID or `<application>/leader` is accepted; there is no wildcard in either major version, and `/leader` is wrong for any action that must touch every unit (package upgrades). Juju's `--wait` is a Go duration, so `--wait=300` fails with `time: missing unit in duration "300"` — it must be `--wait=300s`. Compounding this: `trilio-data-mover` and `trilio-horizon-plugin` are **subordinate** charms, so their units appear under the principal unit's `subordinates` in `juju status --format=json`, *not* under `applications[<app>]['units']` — any loop over the latter silently covers zero data-mover units while appearing to succeed. Enumerate both places (see the `trilio_units` helper on Confluence page 5051482119) and check `status: completed` per unit; a loop over a bad unit name fails without upgrading anything and is easy to miss.

### Gotcha: `juju refresh` alone never installs packages newly added to `base_packages`
Package installation in `data_mover_handlers.py` (and the equivalent handler in the other charms) is gated on:
```python
if is_trilio_pkg_source_changed or not reactive.is_state('triliovault-packages.installed'):
    run_trilio_install_upgrade_packages(packages_to_install)
```
`triliovault-packages.installed` is sticky and `upgrade-charm` does not clear it, so on an already-deployed unit a charm refresh swaps hook code **only**. If the new revision adds a package to `base_packages` — as 6.2 did with `python3-trilio-dms` — and also adds the matching service to `services`, the charm starts asserting a service whose package it never installed, and the unit sits **blocked** forever with `Services not running that should be: <svc>`. The escape hatch is the `update-trilio` action: it calls `run_trilio_upgrade()` → `do_trilio_pkg_upgrade()` → `fetch.apt_install(self.all_packages, fatal=True)`, which bypasses the gate entirely. This is why the Confluence upgrade procedure marks `update-trilio` as required after every refresh — it is not optional hygiene, it is the only path that installs new packages.

### Gotcha: `triliovault-pkg-source` must be changed *after* the charm refresh settles, never before
`install_source_changed()` fires on `config.changed.triliovault-pkg-source` and the install runs against **whichever charm code is active at that moment**. Change the source before/while the refresh is still landing and the outgoing revision consumes it, installs its own (older) `base_packages` list, and `reactive.helpers.data_changed('triliovault-pkg-source', ...)` records the new value. The incoming revision then evaluates `is_trilio_pkg_source_changed` as **False** — permanently — so its larger package list is never installed and the only remaining recovery is `update-trilio`. Diagnose this from the unit log by comparing the package list in the `Installing [...]` line against the `Trilio Datamover Charm Packages: [...]` line that follows the `upgrade-charm` hook; if the second list is longer, the install ran on the old charm. Ordering is documented as Upgrade Step 2 → Step 3 on Confluence page 5051482119.

### Gotcha: removing a Trilio package masks its systemd unit (survives redeploy)
Trilio debs are built with stock debhelper, whose `postrm` calls `deb-systemd-helper mask` on `remove`. So `apt remove python3-trilio-dms` leaves `/etc/systemd/system/trilio-dms-server.service -> /dev/null` plus a marker in `/var/lib/systemd/deb-systemd-helper-masked/`, and the mask **persists on the machine** across a full `juju remove-application` + redeploy. On QA setups where compute nodes are reused, this shows up as a confusing `Unit trilio-dms-server.service is masked` on a "fresh" deployment. It is a symptom, not the cause — the real problem is that the package is not installed (`dpkg -l` shows `rc`, not `ii`). No manual `systemctl unmask` is needed: the package's `postinst` runs `deb-systemd-helper unmask`, which clears masks d-s-h itself created, so simply reinstalling the package is sufficient. Always check `dpkg -l <pkg>` state before chasing a mask.

### Gotcha: a password over a custom relation is not DB access — the grant comes from `shared-db`
`mysql-innodb-cluster` creates a `'<user>'@'<host>'` grant **only for hosts that requested the database over their own `shared-db` → `db-router` chain**. Handing another charm the password over a bespoke relation therefore produces a perfectly valid credential that cannot connect: the DMS client on DMAPI got the `workloadmgr` password via a `wlm-db` relation from `trilio-wlm`, but the only grant in existence was `workloadmgr@<wlm-ip>`, so every backup target mount died on `ERROR 1045 Access denied for user 'workloadmgr'@<dmapi-ip>` (TVAULT-7592). The fix is to add the *other service's* database to the consuming charm's own `get_database_setup()` with a distinct `prefix`:
```python
{"database": "workloadmgr", "username": "workloadmgr", "prefix": "wlm"},
```
This does **not** create a second DB user or rotate anything. `mysql-innodb-cluster` stores the password **per username** in a single leader key (`mysql-<username>.passwd`) — verified in the field, where the `dmapi` username has four host grants (dm-api + three data-mover units) all sharing one `mysql-dmapi.passwd`. A second requester for the same username gets that same password back plus a grant for its own host; `CREATE DATABASE IF NOT EXISTS` leaves the schema and data untouched. Multi-prefix requests do pass through `mysql-router` correctly (`nova-mysql-router` forwards `nova_*`/`novaapi_*`/`novacell0_*`), and this charm set already relies on it — `trilio-data-mover` requests the `dmapi` database on compute nodes the same way. Diagnose this class of bug with `SELECT user,host FROM mysql.user` on the innodb-cluster primary, **not** by checking that the rendered config has a plausible-looking URL.

### Gotcha: "config renders correctly" is not "the credential works"
Directly related to the above, and the reason TVAULT-7592 survived a full upgrade-and-backup verification round: the documented check was that `db_url` in `/etc/triliovault-dms/client.conf` was a populated `mysql+pymysql://...` URL, and it always was. On the setup where that verification ran, `sending DMS mount request` appeared **zero** times in the DMAPI log — the mount path was never exercised, because the old static `/var/triliovault-mounts` mounts from the 6.1.x baseline were still in place and DMS never needed a dynamic mount. Any verification of a rendered credential must actually **connect** with it, and any Canonical upgrade test must take a snapshot **after** `unmount-old-backup-targets`, which is what forces the first real dynamic mount.

### Gotcha: `alembic.ini` is charm-rendered, so `db_sync()` must never run before the render
`/etc/triliovault-wlm/alembic.ini` comes from `charm-trilio-wlm/src/templates/alembic.ini`, **not** from the `workloadmgr` deb (`dpkg -L workloadmgr` has no alembic file). So on a **fresh install** the file does not exist until `render_with_interfaces()` runs. The TVAULT-7522 fix deliberately moved `charm_class.db_sync()` *ahead* of that render, so wlm-api/workloads/scheduler/cron would not restart against an unmigrated schema — correct on an upgrade, fatal on a fresh install:
```
alembic --config=/etc/triliovault-wlm/alembic.ini upgrade head -> exit 255
FAILED: No config file '/etc/triliovault-wlm/alembic.ini' found
```
`db_sync()` kills the hook *before* the render that would have created the file, and every Juju retry hits the same wall — the unit deadlocks in `hook failed: "identity-service-relation-changed"` forever. **Upgrades never expose this** because `alembic.ini` is already on disk from the previous release's render, which is exactly why upgrade-only verification passed it (TVAULT-7592). The fix is to render that one file first — its `restart_map` entry is `[]`, so it restarts nothing and the TVAULT-7522 ordering still holds:
```python
charm_class.render_with_interfaces(args, configs=[charm_class.alembic_ini])
charm_class.db_sync()
charm_class.render_with_interfaces(args)
```
General rule for these charms: **any charm-rendered file that a migration/bootstrap command reads must be rendered before that command runs**, and reordering a migration relative to a render must always be re-tested on a fresh install, never on an upgrade alone.

### Gotcha: every `restart_map` key needs a convention-named template, or `render_with_interfaces()` dies
`charms_openstack` renders each `restart_map` key by deriving a template name from the file path — `/etc/triliovault-dms/server.conf` is looked up as `server.conf`, then `etc_triliovault-dms_server.conf`. `charm-trilio-data-mover` listed that path plus `/etc/triliovault-dms/s3vaultfuse-global.conf` in its `restart_map`, but its template is named `triliovault-dms-server.conf` and the s3vaultfuse file has no template at all. Every `render_with_interfaces()` over the full map therefore raised `Could not load template ... from None`, which made the **`update-trilio` action fail on all three data-mover units** on a 6.1.8 → 6.2.1 upgrade (TVAULT-7592). Normal hooks were unaffected because the DMS server config is written by an explicit `render(source='triliovault-dms-server.conf', ...)` call, so this only surfaced on the action path — and only if you check `status:` per unit, which is exactly the failure mode the Confluence doc warns about. Keep charm-rendered files that have a non-conventional template name **out** of `restart_map` and render them explicitly (this is what `charm-trilio-dm-api` does with its DMS client conf); the explicit writer restarts the service itself, so nothing is lost.

### Gotcha: `alembic upgrade head` is a no-op when the DB already exists — only `update-trilio` migrates
Running `alembic --config=/etc/triliovault-wlm/alembic.ini upgrade head` against an existing `workloadmgr` database prints `Database Already Exists` and **exits 0 without applying anything**. Measured on a real 6.1.8 → 6.2.1 upgrade: the package shipped migrations through `031` while `alembic_version` sat at `027`, and `db_sync()` calls from `render_config()`/`init_db()` changed nothing. `wlm-workloads` then crash-looped on `Unknown column`-style SQL errors against `backup_targets.secret_ref`. The `update-trilio` action is what actually advanced the schema `027 → 031`. This is the concrete reason Confluence marks Step 4 mandatory and why the "re-run `update-trilio` if you see a DB column error" note exists — a green `db_sync()` proves nothing.

### Always test fresh install *and* upgrade — they exercise different code
Two separate 6.2.1 blockers (TVAULT-7592's missing MySQL grant, and the `alembic.ini` deadlock above) both survived a full upgrade-and-backup verification round and both broke on the paths the other test would have caught. Upgrades inherit on-disk state (rendered configs, existing DB grants, migrated schemas) that a fresh install must create from nothing; fresh installs skip the migration/`update-trilio` logic that upgrades depend on. Passing one says nothing about the other. Every charm change needs both, and the fresh-install run must start from a genuinely clean slate — see the Uninstall section, especially dropping the DBs **and every grant row**.

### Gotcha: reactive handlers gated only on relation flags run on *every* hook
`@reactive.when('shared-db.available')` + `@reactive.when('amqp.available')` stay true for the life of the deployment, so such a handler fires on every hook — `update-status` included, roughly every 5 minutes. An unguarded `host.service_restart()` at the end of one of these is therefore an infinite restart loop, not a one-off: `tvault-datamover-api` was observed bouncing every ~4-5 minutes indefinitely, killing any snapshot mid-transfer. Guard with `reactive.helpers.data_changed(...)` **plus** an on-disk staleness check (a package reinstall can blank the file without any relation data changing), and add `@reactive.when_not('is-update-status-hook')`. See `render_dms_client_config()` / `_dms_client_conf_is_stale()` in `charm-trilio-dm-api` and `render_dms_config()` / `_dms_server_conf_is_stale()` in `charm-trilio-data-mover`. Related trap: two handlers writing the same file with different content (one bootstrap render with a blank `db_url`, one real render) will fight on every hook — render a single context from one code path instead.

### Object-store service cleanup (6.1 → 6.2 upgrade)
6.2 removes static/`tvault-object-store.service`-based backup targets in favor of dynamic per-target mounts managed by `trilio-dms-server`. Leftover per-target systemd units follow the pattern `tvault-object-store-<BT_NAME>.service` (created dynamically by the DMS/s3vaultfuse runtime, not templated anywhere in this repo) and will auto-remount a target's FUSE/NFS mount if left running — `unmount_old_backup_targets()` must stop, disable, **and remove** the unit file (not just unmount), or the mount comes right back. See `unmount-old-backup-targets` action in `charm-trilio-wlm` and `charm-trilio-data-mover`.

### Canonical install/upgrade procedure references
- **6.1.x fresh install**: follow the official published guide, https://docs.trilio.io/openstack/deployment/installing-on-canonical — this is the baseline procedure (bundle prep, deploy, trust/license, backup targets) for 6.1 and earlier releases on Canonical OpenStack.
- **6.2+ install/upgrade changes**: the Confluence page "6.2.1 Install and Upgrade Step Changes for Canonical" (page 5051482119, space TVO) documents what's *different* from the 6.1.x baseline above — new relations (e.g. the required-but-easy-to-miss `juju add-relation trilio-data-mover:identity-service keystone:identity-service`), removed static backup-target config, the `update-trilio` action requirement, etc. Read it as a diff against the 6.1.x guide, not a standalone doc.

Check both before debugging any Canonical upgrade Jira — QA repro steps pasted into a Jira sometimes omit a step from one or the other.

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

Uninstall is a **single discrete step, run to full completion before starting any new deploy** — not something to interleave with a redeploy, and not something to partially do mid-test. Doing it out of order (e.g. dropping the database while a fresh deploy's `shared-db` relation is still negotiating) creates a race: the relation can finish provisioning a fresh database *after* you've dropped it, leaving the charm's rendered config pointing at credentials that no longer have a matching grant. Always: (1) remove the Juju applications and wait for removal to fully finish, (2) only then clean Keystone/RabbitMQ/MySQL, (3) only then start the next deploy.

### Step 1 — Remove the Juju applications
Remove all four principal charms **and their mysql-router subordinates explicitly** in one command — don't rely on subordinates being auto-removed, they can be left behind as orphaned applications:

```bash
juju remove-application trilio-wlm trilio-dm-api trilio-data-mover trilio-horizon-plugin \
  trilio-dm-api-mysql-router trilio-wlm-mysql-router trilio-data-mover-mysql-router
```

Units commonly go into `error` state during removal (see gotcha below) — once they do, re-run the same command with `--force` (add `--no-wait` too if it still doesn't progress):

```bash
juju remove-application trilio-wlm trilio-dm-api trilio-data-mover trilio-horizon-plugin \
  trilio-dm-api-mysql-router trilio-wlm-mysql-router trilio-data-mover-mysql-router --force
```

Confirm full removal before proceeding — `juju status <app-names>` should return "Nothing matched specified filters" for every one of them.

### Gotcha: removal commonly errors on unrelated interface-library bugs — safe to force through
Removing these charms (or redeploying shortly after, causing relation churn on `mysql-innodb-cluster`) frequently triggers hook failures unrelated to Trilio's own code, in shared/vendored interface libraries:
- `identity-service-relation-departed` can fail with `IndexError: list index out of range` in `hooks/relations/keystone/requires.py` (`self.relations[0]` accessed without checking the list is non-empty once the other side has already departed).
- On the `mysql-innodb-cluster` side, `db-router-relation-broken` can fail with `network-get --primary-address cluster` returning a non-zero exit — this can affect **all** `mysql-innodb-cluster` units, not just the one related to Trilio.
- Also on `mysql-innodb-cluster`, the periodic `update-status` hook can fail with `relation-get ... returned non-zero exit status 1` / `settings not found`, referencing a stale relation ID left over from a torn-down relation — this isn't limited to the moment of removal, it can resurface on any later `update-status` tick and will itself **block new `db-router` requests** (a freshly redeployed charm's `mysql-router` subordinate will sit at "MySQL Router not yet bootstrapped" indefinitely until this is resolved).

All three are pre-existing hook-script bugs (not data-loss or live-service issues) — verify with `systemctl is-active mysql` on a `mysql-innodb-cluster` unit and check that unrelated apps sharing the same DB backend (e.g. `keystone`, `cinder`, `glance`) are still `active` before proceeding. Once confirmed, `juju resolved --no-retry <unit>` on each affected unit is safe. If a fresh deploy's `mysql-router` subordinate is stuck bootstrapping, check `juju status mysql-innodb-cluster` for this exact symptom before assuming the new deploy itself is broken.

### Step 2 — Clean Keystone (only after Step 1 is fully complete)
Trilio registers `dmapi` and `workloadmgr` as Keystone services, each with 3 endpoints (admin/public/internal), and a service-account user for each — commonly duplicated across more than one domain (e.g. a Juju-created `service_domain` in addition to `default`), so check both:

```bash
source <openrc file>
openstack --insecure endpoint list | grep -iE 'dmapi|workload'   # note IDs, then:
openstack --insecure endpoint delete <id>                        # for each endpoint

openstack --insecure service list | grep -iE 'dmapi|workload'    # note IDs, then:
openstack --insecure service delete <id>                         # for each service

openstack --insecure domain list                                  # check every domain, not just default
openstack --insecure user list --domain <domain-id> | grep -iE 'dmapi|workload'
openstack --insecure user delete <id>                             # for each user, in every domain it appears
```

### Step 3 — Clean RabbitMQ (only after Step 1 is fully complete)
Trilio creates a vhost (commonly named after the wlm service, e.g. `triliowlm`) and per-service users (`dmapi`, `datamover`, and the wlm vhost-named user):

```bash
sudo rabbitmqctl list_vhosts   # identify the trilio vhost
sudo rabbitmqctl list_users    # identify trilio users
sudo rabbitmqctl delete_vhost <vhost>
sudo rabbitmqctl delete_user <user>   # for each trilio-related user
```

### Step 4 — Clean MySQL (only after Step 1 is fully complete)
`juju remove-application` never drops the actual database in `mysql-innodb-cluster` — the schema and all data persist independently, cached under `mysql-innodb-cluster`'s own leader-settings (keyed by service name, e.g. `dmapi`/`workloadmgr`, not by unit). If you're tearing down specifically to test an older release's fresh-install-then-upgrade path, this matters a lot: redeploying against a database that's already at the newer schema means `db_sync()`/alembic migration during the later upgrade step is a no-op, silently defeating the entire point of the test. Root credentials are in `leader-get` on a `mysql-innodb-cluster` unit — look for the plain `mysql.passwd` key, and the per-service `mysql-<service>.passwd` keys:

```sql
DROP DATABASE IF EXISTS workloadmgr;
DROP DATABASE IF EXISTS dmapi;
-- then find and drop every matching grant, not just one IP:
SELECT user, host FROM mysql.user WHERE user IN ('dmapi', 'workloadmgr');
DROP USER IF EXISTS '<user>'@'<host>';   -- repeat per row above
```

Expect **more than one host per username** — since 6.2.1 the `workloadmgr` user is granted to the `trilio-dm-api` host as well as the `trilio-wlm` host (see the `shared-db` grant gotcha above), and `dmapi` is granted to every `trilio-data-mover` (compute) host plus the dm-api host. Always drop by iterating the `SELECT` above rather than assuming one row per user, or a later fresh-install test will silently reuse a stale grant.

Only start the next deploy once Steps 2–4 are all confirmed clean — never drop these while a deploy's `shared-db`/`identity-service`/`amqp` relations are still negotiating (`juju status` showing `incomplete`/`waiting`).

### Step 5 — Clean leftover host-level services (6.1.x and older only)
6.1.x and earlier use the static/`tvault-object-store.service`-per-backup-target architecture that 6.2 removed entirely (see "What Changed in 6.2" above). These run as raw systemd services on the underlying host/container, **outside the charm's own install/remove hook lifecycle** — `juju remove-application` does not stop or clean them up, so they can keep running (or crash-looping) for days across multiple teardown/redeploy cycles, on both `trilio-data-mover` **and** `trilio-wlm` nodes:

- `trilio-dms-server.service` — only found running on `trilio-data-mover` nodes in a 6.1.x deployment (it's a 6.2+-introduced component elsewhere, but can be left over from a prior 6.2 test on the same nodes).
- `tvault-object-store-<BT_NAME>.service` (e.g. `tvault-object-store-S3_BT1.service`) — one per configured backup target, on **both** `trilio-data-mover` and `trilio-wlm` nodes. If stale ones are left running from a previous test, a fresh charm can report `blocked`/`Services not running that should be: ...` even though the *real* problem is that old, orphaned units are still active (or crash-looping) under the same name and the fresh charm's own service was never actually (re)created.

Check and clean on every `trilio-data-mover` and `trilio-wlm` unit:

```bash
sudo systemctl status trilio-dms-server --no-pager   # data-mover nodes
sudo systemctl list-units --all --plain --no-legend 'tvault-object-store-*.service'

# for each leftover service found:
sudo systemctl stop <service>
sudo systemctl disable <service>
sudo rm -f "$(systemctl show <service> -p FragmentPath --value)"
sudo systemctl daemon-reload

# also verify no stale mounts/processes remain:
findmnt -rn -o TARGET,FSTYPE | grep triliovault-mounts
ps aux | grep -i s3vaultfuse
```

Do this as part of Step 1 (alongside or right after the Juju application removal), before Steps 2–4 and before any fresh redeploy — a leftover crash-looping object-store service can otherwise make a perfectly fine fresh 6.1.x deploy look broken.

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
