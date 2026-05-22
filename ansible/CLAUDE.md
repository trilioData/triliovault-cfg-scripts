# Ansible Deployment Scripts

## Overview
Generic Ansible roles for deploying TrilioVault (T4O) on bare-metal or VM-based OpenStack installations.
These roles are distribution-agnostic and target OpenStack clouds where Kolla, Juju, or RHOSP are not used.

## Directory Structure

```
ansible/
├── main-install.yml                              # Top-level playbook entry point
├── environments/
│   ├── hosts                                     # Ansible inventory
│   └── group_vars/all/vars.yml                   # Global variables for all hosts
└── roles/
    ├── openstack-ansible-os_triliovault_wlm/     # WorkloadManager service role
    ├── ansible-datamover-api/                    # DataMover API (dmapi) service role
    ├── ansible-tvault-contego-extension/         # DataMover (contego) service role
    └── ansible-horizon-plugin/                   # Horizon UI plugin role
```

## Role Structure (same layout for all roles)

```
roles/<role-name>/
├── defaults/main.yml     # Default variables (override in group_vars or extra-vars)
├── vars/main.yml         # Internal role variables (not for external override)
├── handlers/main.yml     # Handlers (service restart triggers)
├── meta/main.yml         # Role metadata and dependencies
├── tasks/
│   ├── main.yml          # Task entry point — imports other task files
│   ├── install_ubuntu.yml
│   ├── install_rhel.yml
│   ├── service_setup.yml
│   ├── db_setup_*.yml    # Database initialisation per OS/release variant
│   ├── create_endpoint.yml
│   ├── mq_setup.yml      # RabbitMQ setup
│   └── uninstall.yml
├── templates/            # Jinja2 config templates (.j2)
│   ├── triliovault-<component>.conf.j2
│   ├── <component>_logging.conf.j2
│   ├── trilio.repo       # YUM/DNF repository template
│   └── trilio.list       # APT repository template
└── files/                # Static files
```

## Technology Stack
- **Ansible**: Orchestration and task automation
- **Jinja2**: Config file templating (`.j2` files)
- **Dual OS support**: Ubuntu (APT/`.list`) and RHEL/CentOS (YUM/DNF/`.repo`)
- **Systemd**: Service management on target hosts

## Key Conventions

### OS-Specific Install Tasks
Each role separates OS-specific package installation:
- `install_ubuntu.yml` — uses APT, `trilio.list` template
- `install_rhel.yml` — uses YUM/DNF, `trilio.repo` template

### Database Setup
Database initialisation is split per OpenStack release (Ussuri, Victoria, etc.) to handle schema differences:
- `db_setup_ussuri.yml`, `db_setup_victoria.yml`, etc.

### Variables
- `defaults/main.yml` — safe to override via `group_vars`, `host_vars`, or `--extra-vars`
- `vars/main.yml` — internal constants; do not override externally

## Deployment Flow
1. Fill in `environments/hosts` with your inventory (control/compute nodes)
2. Set cloud-specific values in `environments/group_vars/all/vars.yml`
3. Run: `ansible-playbook -i environments/hosts main-install.yml`
