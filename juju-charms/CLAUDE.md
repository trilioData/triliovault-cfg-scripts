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
3. Create a symlink: `src/actions/<action-name>` → `actions.py`

### Wheelhouse / Offline Dependencies
`src/wheelhouse.txt` lists pip packages to bundle. Pre-downloaded `.whl` files go in `src/wheelhouse/`.
Required when the charm target nodes have no internet access.

## Build and Publish Workflow

```bash
# From within the charm subdirectory:
cd juju-charms/charm-trilio-wlm

# Build
charmcraft pack

# Upload to Charmhub (produces a revision number)
charmcraft upload trilio-charmers-trilio-wlm_ubuntu-22.04-amd64.charm

# Release to a channel
charmcraft release trilio-charmers-trilio-wlm --revision <N> --channel latest/stable
```

Run the same commands from each charm's subdirectory independently.

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
