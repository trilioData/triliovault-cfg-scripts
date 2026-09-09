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

## DMS runtime directory (/run/dms) — TVAULT-7655
- **`/run` is a tmpfs, so a runtime directory there must be created by `tmpfiles.d`, never by a one-shot Ansible `file:` task.** `config.yml` used to create `/run/dms` on the host with a `file:` task, but the DMS container carries a restart policy, so the container engine brings it back on every boot into a `/run` that was just emptied — and it runs as nova (42436), so it can never recreate a directory under a `root:root` `/run`. The DMS server then fails permanently with `Permission denied: '/run/dms'` until `kolla-ansible reconfigure` is re-run. The role now ships `/etc/tmpfiles.d/trilio-dms.conf` (`templates/trilio_dms_tmpfiles_conf.j2`) and applies it immediately with `systemd-tmpfiles --create`; `systemd-tmpfiles-setup.service` is ordered `Before=sysinit.target`, so it always wins against `docker.service`/`podman.service`. Diagnosed first on RHOSO18 — see `redhat-director-scripts/rhosp18/CLAUDE.md` for the full analysis.
- **The DMS container DOES mount the host's `/run` (`/run:/run:shared`), and must keep doing so — `/run/dms` has to be node-scoped.** There are two separate requirements: the **directory** must exist after a reboot (contents may be empty), and the **contents** must survive a container recreate, because the s3vaultfuse FUSE mounts outlive the container via `triliovault_parent_data_directory:shared`. `tmpfiles.d` gives the first, the host bind mount gives the second, and **neither alone is sufficient**: TVAULT-7655 was the first one failing, and its original fix (baking `/run/dms` into the DMS image and dropping the `/run` mount, PR #1585) broke the second — the image layer itself is read-only and survives a recreate, but the pid and lock files written on top of it land in the container's writable overlay, which the engine discards, so they would vanish while the mounts stayed live and orphan silently. Do not re-remove that mount, and do not move the tree somewhere disk-backed (e.g. under `/var/lib`) — that would preserve pid files across a reboot, which the DMS dev team explicitly does not want.
- **The DMS images deliberately do NOT create `/run/dms`, and must not start doing so again.** Every consumer of every `trilio-dms` image supplies the directory itself — kolla and the RHOSO18 data plane from `/etc/tmpfiles.d/trilio-dms.conf` under a host `/run` bind mount, the openstack-helm DaemonSet/Deployment and the RHOSO18 ctlplane DaemonSet from a root init container under a hostPath or emptyDir `/run` — so a tree baked into the image is masked everywhere it ships. It only misleads whoever inspects the image, and it cannot hold the recreate state anyway.
- **Whatever creates `/run/dms` must own `/run/dms` itself, not just `/run/dms/s3`.** The server creates the missing `s3` and `locks` subdirectories with `os.makedirs()`, which needs write permission on the parent.
- **The tmpfiles owner is bound to `triliovault_services['triliovault-dms'].run_user`**, the identity the container is actually started with, so overriding `triliovault_datamover_user_id` cannot leave the directory owned by a uid the DMS process does not have.
- **The tmpfiles `age` field must stay `-`.** Any value there lets `systemd-tmpfiles-clean.timer` delete live pid and lock files under `/run/dms` on a schedule, out from under a running mount.

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

### Known Constraints
- **`gather_facts: false` relies on kolla-ansible's fact cache**: `triliovault_site_<version>.yml` plays run with `gather_facts: false`, but templates still reference `ansible_*` facts (e.g. `ansible_fqdn`, `ansible_<iface>.ipv4.address`). This works because kolla-ansible's own deployment (a prerequisite before installing the T4O add-on) already gathered and cached facts for the same inventory. Don't assume facts are missing just because this playbook disables gathering.
- **DMS `node_id` must be `ansible_fqdn`, not `inventory_hostname`**: `inventory_hostname` is just the name/alias used in the Ansible inventory file and is not guaranteed to be a resolvable hostname. DMS server `node_id` must match `OS-EXT-SRV-ATTR:host` from nova, and client-side `node_id` must be a real FQDN — use `ansible_fqdn` in these templates.
