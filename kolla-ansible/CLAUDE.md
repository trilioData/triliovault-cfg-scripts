# Kolla Ansible Deployment Scripts

## Overview
Ansible roles and playbooks for deploying TrilioVault (T4O) on Kolla-Ansible based OpenStack clouds.
Kolla containerises all OpenStack services; T4O plugs in as additional containers managed through an Ansible role that mirrors Kolla's own patterns.

## Code Development Philosophy 
- We follow upstream kolla-ansible openstack deployment scripts as reference to develop our deployment scripts. 
- OpenStack kolla-ansible git code repo - https://github.com/openstack/kolla-ansible
- We refer kolla-ansible openstack support matrix to check which host operating systems we need to support. Sample document for epoxy release: https://docs.openstack.org/kolla-ansible/latest/user/support-matrix.html
- We check Kolla-ansible openstack release notes for each release for any changes in their deployment scripts that may affect our sripts. Like any global variable gets removed, changed or newly added etc.
- Sample release notes for kolla-ansible openstack Epoxy release is: https://docs.openstack.org/releasenotes/kolla-ansible/2025.1.html
- Claude should also check these points while developing the code for T4O deployment scripts.

## T4O Install Document on Kolla-Ansible OpenStack. You need to update branch name in the url, in this case it 't4o-5.x' for all releases of T4O 5.x
https://docs.trilio.io/openstack/t4o-5.x/deployment/installing-on-kolla

## Supported OpenStack Versions
| File suffix | OpenStack Release |
|-------------|-------------------|
| `_zed` | Zed |
| `_2023.1` | Antelope |
| `_2023.2` | Bobcat |
| `_2024.1` | Caracal |
| `_2024.2` | Dalmatian |
| `_2025.1` | Epoxy |
| `_2025.2` | Flamingo |

## Directory Structure

```
kolla-ansible/
├── ansible/
│   ├── roles/triliovault/          # Main Ansible role
│   │   ├── defaults/main.yml       # All role variables and defaults
│   │   ├── handlers/main.yml       # Handlers (restart triggers)
│   │   ├── meta/main.yml           # Role dependencies
│   │   ├── tasks/
│   │   │   ├── main.yml            # Task entry point — imports other task files
│   │   │   ├── check.yml           # Pre-deployment validation
│   │   │   ├── bootstrap.yml       # First-time setup (DB, Keystone, RabbitMQ)
│   │   │   ├── config.yml          # Generate and push config files to nodes
│   │   │   ├── deploy.yml          # Deploy T4O containers
│   │   │   ├── register.yml        # Register Keystone endpoints
│   │   │   ├── upgrade.yml         # Upgrade running containers
│   │   │   ├── reconfigure.yml     # Push config changes without full redeploy
│   │   │   ├── stop.yml            # Stop T4O containers
│   │   │   ├── loadbalancer.yml    # HAProxy config for VIP endpoints
│   │   │   ├── ceph_cinder.yml     # Ceph/Cinder integration
│   │   │   ├── ceph_nova.yml       # Ceph/Nova integration
│   │   │   └── rabbitmq.yml        # RabbitMQ vhost/user setup
│   │   └── templates/              # Jinja2 config templates (.j2)
│   │       ├── triliovault-wlm.conf.j2
│   │       ├── triliovault-datamover.conf.j2
│   │       ├── triliovault-datamover-api.conf.j2
│   │       ├── api-paste.ini.j2
│   │       ├── fuse.conf.j2
│   │       └── start-triliovault-*.sh.j2   # Container startup scripts
│   ├── triliovault_globals_<version>.yml   # Per-version global variables
│   ├── triliovault_site_<version>.yml      # Per-version site playbook
│   ├── triliovault_passwords.yml           # Vault-encrypted service passwords
│   ├── triliovault_inventory.txt           # Inventory (control/compute groups)
│   ├── input_values.txt                    # Input template — fill before deploying
│   └── scripts/
│       ├── prepare_triliovault_role.py     # Prepare role for target cloud
│       ├── generate_password.sh            # Generate random passwords
│       └── migrate_backup_targets_62.sh    # Backup target migration helper
└── generate-dynamic-values.sh             # Generate dynamic config at deploy time
```

## Technology Stack
- **Ansible**: Orchestration, task automation, inventory management
- **Jinja2**: Config file templating (`.j2` files; same engine as Kolla itself)
- **Docker / Podman**: Container runtime for T4O service containers
- **HAProxy**: Load balancing for T4O API endpoints
- **Ceph**: Optional block/object storage backend

## Key Conventions

### Per-Version Files
Each supported OpenStack release has its own globals and site playbook:
- `triliovault_globals_<version>.yml` — version-specific variable overrides
- `triliovault_site_<version>.yml` — top-level playbook that imports the role

Always use the file matching the target cloud's OpenStack release.

### Role Variables
All configurable parameters are in `roles/triliovault/defaults/main.yml`.
Override them in the appropriate `triliovault_globals_<version>.yml` before deployment.

### Jinja2 Templates
Templates follow Kolla naming: `triliovault-<component>.<ext>.j2`
Variables come from `defaults/main.yml` and injected globals. Use `{{ variable }}` for substitution.

### Task File Mapping (mirrors Kolla CLI tags)
| Kolla tag | Task file |
|-----------|-----------|
| `bootstrap` | `bootstrap.yml` + `bootstrap_service.yml` |
| `config` | `config.yml` |
| `deploy` | `deploy.yml` + `deploy-containers.yml` |
| `reconfigure` | `reconfigure.yml` |
| `upgrade` | `upgrade.yml` |
| `stop` | `stop.yml` |

### Deployment Flow
1. Fill in `input_values.txt` with cloud-specific values
2. Run `scripts/prepare_triliovault_role.py` to set up the role
3. Run `generate-dynamic-values.sh` to produce runtime config
4. `ansible-playbook -i triliovault_inventory.txt triliovault_site_<version>.yml`
