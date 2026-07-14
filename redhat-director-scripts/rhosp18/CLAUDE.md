# RHOSO 18 Deployment Scripts

## Overview
Deployment scripts for TrilioVault (T4O) on Red Hat OpenStack Services on OpenShift (RHOSO) 18.0.
RHOSO 18 runs OpenStack services as Kubernetes/OpenShift workloads — control plane services are deployed as a Kubernetes Operator, data plane services are deployed via Ansible.

Reference: https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/18.0/html/deploying_red_hat_openstack_services_on_openshift/index

## Architecture

| Plane | Deployment Method | Components |
|-------|------------------|------------|
| Control plane | Kubernetes Operator (via Helm) | wlm-api, wlm-workloads, wlm-cron, wlm-scheduler, dmapi |
| Data plane | Ansible | datamover (one per nova-compute node) |

## Directory Structure

```
rhosp18/
├── ctlplane-scripts/               # Control plane deployment
│   ├── build/                      # Operator SDK build and publish scripts
│   ├── operator/tvo-operator/      # Operator source (Go, Operator SDK)
│   │   ├── config/                 # K8s manifests (CRDs, RBAC, manager)
│   │   ├── helm-charts/tvo-chart/  # Helm chart embedded in operator
│   │   │   ├── conf/               # Service config templates (.tpl)
│   │   │   ├── scripts/            # Container init scripts (.sh.tpl)
│   │   │   └── templates/          # Kubernetes resource templates
│   │   │       ├── datamover-api/
│   │   │       ├── galera/         # MySQL HA cluster
│   │   │       ├── rabbitmq/
│   │   │       └── workloadmgr/
│   │   └── Makefile                # Operator build targets
│   ├── dev/                        # Development utilities
│   ├── deploy_tvo_control_plane.sh # Main control plane deployment entry point
│   ├── install_operator.sh         # Install TVO operator via OLM
│   ├── create_cert_secrets.sh      # Create TLS secrets
│   └── operator-rbac.yaml          # RBAC for operator service account
└── dataplane-scripts/              # Data plane deployment
    ├── build/                      # Container image build scripts
    └── ansible-roles/              # Ansible roles for compute nodes
```

## Technology Stack
- **Operator SDK / Go**: The TVO operator manages the lifecycle of Helm-released control plane services
- **Helm**: Kubernetes resource templating embedded inside the operator
- **OpenShift / Kubernetes**: CRDs, RBAC, Routes (OpenShift-specific ingress), OLM bundle format
- **Galera**: MySQL high-availability clustering for WLM and DMAPI databases
- **RabbitMQ**: Message broker for T4O service communication
- **Ansible**: Deploys and configures datamover on compute nodes

## Key Conventions

### Helm Chart Templates
- Config templates: `conf/_<component>-<purpose>.tpl` (e.g., `_api-paste.ini.tpl`)
- Init scripts: `scripts/_triliovault-<component>-<action>.sh.tpl`
- Kubernetes resources organised by service under `templates/`

### Operator Build
- `make` in `operator/tvo-operator/` builds and packages the operator
- `build/build_operator_image.sh` builds the operator container image
- `build/publish_operator.sh` pushes to registry
- OLM bundle format used for OperatorHub distribution

### Deployment Flow
1. `create-image-pull-secret.sh` — registry credentials
2. `create_cert_secrets.sh` — TLS certificates
3. `install_operator.sh` — install TVO operator
4. `deploy_tvo_control_plane.sh` — deploy control plane via operator
5. `dataplane-scripts/` Ansible roles — install datamover on compute nodes

## Known Constraints
- **`containers.podman.podman_container` with `state: stopped` fails if the container doesn't exist**: it tries to *create* the container (requiring an `image` param) rather than no-op, erroring `Cannot create container when image is not specified!`. `state: absent` does not have this problem — it force-stops and removes the container in one step regardless of whether it's running or already gone. When a task list stops then removes the same container, the explicit stop task is redundant; drop it rather than adding `ignore_errors: true` band-aids (TVAULT-7487, `trilio-datamover/tasks/delete-backup-target.yml`).
- **Backup target containers are systemd-managed, not bare `podman run`**: `add-backup-target.yml` creates the S3/NFS containers via the `osp.edpm.edpm_container_manage` role, which generates systemd units `edpm_triliovault-object-store-<name>.service` / `edpm_triliovault-nfs-container-<name>.service` (see `handlers/main.yml`). Any task that removes these containers directly via `podman_container: state: absent` **must first stop and disable the systemd unit** — otherwise the unit can respawn the container out from under you, and the "container removed" task can report success while the container is still running. Mirror the stop-unit-then-remove-container order already used in `cleanup_old_backup_targets.yml`. This bit TVAULT-7487: the first fix attempt (dropping the redundant "Stop" `podman_container` task) removed the loud error but the container was still left running in production because the systemd unit was never stopped.
- **`podman_container` tasks need `become: true` explicitly** — it is not inherited from neighboring tasks in the same file. In `delete-backup-target.yml`, the "Remove ... container" tasks lacked it while every `ansible.builtin.file` task in the same file had it; running as the unprivileged connection user, `podman_container` couldn't see the root-owned container at all, so `state: absent` silently no-op'd ("ok", no error, no change) instead of failing loudly. A clean "ok" status on a podman task is not proof the container was actually inspected — verify `become` is present when a delete/stop task looks suspiciously too easy.
- **`delete-backup-target.yml` was dropped from `maint/6.2`**: `dataplane-scripts/ansible-roles/trilio-datamover/tasks/delete-backup-target.yml` exists on `maint/6.1` but not on `maint/6.2`, since 6.2 stopped managing backup targets via these devops scripts. Jiras reported against this file must be fixed on `maint/6.1` — don't assume the "6.2.1 Jiras go to maint/6.2" branching convention applies when the affected file doesn't exist there.

## T4O Installation Guide
https://docs.trilio.io/openstack/deployment/installing-on-rhosp/trilio_installation_on_rhoso
