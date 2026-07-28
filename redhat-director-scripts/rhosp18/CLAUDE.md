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

## RabbitMQ CRD split (RHOSO <=18.0.18 vs >=18.0.21/FR6) — TVAULT-7511
- **RHOSO switched RabbitMQ operators at FR6 (18.0.21)**: <=18.0.18 uses the upstream community RabbitMQ Cluster Operator (`rabbitmq.com/v1beta1`, kind `RabbitmqCluster`); >=18.0.21 uses RHOSO's own native operator (`rabbitmq.openstack.org/v1beta1`, kind `RabbitMq`) and no longer deploys the community operator at all. T4O's chart ships two template variants — `templates/rabbitmq-till-18.0.18/` and `templates/rabbitmq/` (native, >=FR6) — and the build scripts (`build_operator_image.sh` / `devops-build-publish.sh`, `--openstack-version` flag) delete the non-matching directory (renaming the survivor to `rabbitmq` for the old variant) so a given operator image only ever ships one CRD kind. Install-time config is split the same way: `tvo-operator-inputs-till-fr5.yaml` / `tvo-operator-inputs-fr6-onwards.yaml`, auto-selected by `set_operator_inputs.py` based on `oc get openstackversion`.
- **Never reuse RabbitMQ PVCs across a CRD-kind change**: each RabbitMQ CR (either kind) generates a fresh, randomly-generated `<name>-default-user` secret on creation, but a reused PVC still has the *old* broker's persisted Mnesia database with the *old* credentials baked in. The mismatch surfaces as `job-triliovault-datamover-api-rabbitmq-init` stuck retrying "RabbitMQ API not reachable" (traces to `401 Unauthorized` on the management API) — confirmed by direct reproduction during 6.1 testing. Any migration between CRD kinds (or even a delete+recreate of the same kind) must also delete `persistence-trilio-rabbitmq-cluster-server-0/1/2` (same PVC naming on both variants), not just the CR.
- **`rabbitmq-cluster.yaml`'s hook has no delete-policy**: it's `helm.sh/hook: post-install,post-upgrade` with no `hook-delete-policy` (predates TVAULT-7511, same in both chart variants). A reconcile landing while the object is mid-delete fails the hook and rolls back the *entire* Helm release (`object is being deleted: rabbitmqs.rabbitmq.openstack.org "trilio-rabbitmq-cluster" already exists`). Rare on a fresh install, much more likely across an upgrade's many reconciles. Add `helm.sh/hook-delete-policy: before-hook-creation` if this bites again.
- **6.1's operator crashes without the `TVOBackupTarget` CRD registered**: `watches.yaml` watches both `TVOControlPlane` and `TVOBackupTarget`; if `tvobackuptargets.tvo.trilio.io` isn't installed (e.g. a cluster only ever set up for 6.2, which dropped backup-target management), the operator pod CrashLoopBackOffs with `no matches for kind "TVOBackupTarget" in version "tvo.trilio.io/v1"`. CRD lives at `operator/tvo-operator/config/crd/bases/tvo.trilio.io_tvobackuptargets.yaml` — apply it before installing the 6.1 operator on a fresh cluster.
- **Backup target secret keys must match `backup_target_name`**: `trilio-openstack-secret.yaml` needs `<NAME>_s3_access_key` / `<NAME>_s3_secret_key` matching each `triliovault_backup_targets[].backup_target_name` entry in `tvo-operator-inputs.yaml`, or WLM/object-store pods hit `CreateContainerConfigError: couldn't find key <NAME>_s3_access_key in Secret`.
- **Release image tags**: `https://docs.trilio.io/openstack/about-trilio-for-openstack/artifacts/<version>` (e.g. `.../6.1.9`) lists the exact published image URLs/tags for that T4O release — check here rather than guessing tag strings when testing/upgrading against a real release.

## Known Constraints
- **`containers.podman.podman_container` with `state: stopped` fails if the container doesn't exist**: it tries to *create* the container (requiring an `image` param) rather than no-op, erroring `Cannot create container when image is not specified!`. `state: absent` does not have this problem — it force-stops and removes the container in one step regardless of whether it's running or already gone. When a task list stops then removes the same container, the explicit stop task is redundant; drop it rather than adding `ignore_errors: true` band-aids (TVAULT-7487, `trilio-datamover/tasks/delete-backup-target.yml`).
- **Backup target containers are systemd-managed, not bare `podman run`**: `add-backup-target.yml` creates the S3/NFS containers via the `osp.edpm.edpm_container_manage` role, which generates systemd units `edpm_triliovault-object-store-<name>.service` / `edpm_triliovault-nfs-container-<name>.service` (see `handlers/main.yml`). Any task that removes these containers directly via `podman_container: state: absent` **must first stop and disable the systemd unit** — otherwise the unit can respawn the container out from under you, and the "container removed" task can report success while the container is still running. Mirror the stop-unit-then-remove-container order already used in `cleanup_old_backup_targets.yml`. This bit TVAULT-7487: the first fix attempt (dropping the redundant "Stop" `podman_container` task) removed the loud error but the container was still left running in production because the systemd unit was never stopped.
- **Stopping/disabling the systemd unit is not enough — the unit file itself must be deleted**: the upstream `osp.edpm.edpm_container_manage` framework's own teardown counterpart, `edpm_container_rm` (role `edpm_container_rm`, task `edpm_podman_container_rm.yml` in the `openstack-k8s-operators/edpm-ansible` repo), does `systemd: state: stopped, enabled: false` *then* deletes `/etc/systemd/system/edpm_<container>.service` and `/etc/systemd/system/edpm_<container>.service.requires` via `ansible.builtin.file: state: absent`, then runs `systemd: daemon_reload: true`, and only then removes the container. Any Trilio task that manually tears down an edpm-managed container should mirror this exact sequence (TVAULT-7487) — `systemctl disable` alone leaves a stale unit file on disk under `/etc/systemd/system/`.
- **`podman_container` tasks need `become: true` explicitly** — it is not inherited from neighboring tasks in the same file. In `delete-backup-target.yml`, the "Remove ... container" tasks lacked it while every `ansible.builtin.file` task in the same file had it; running as the unprivileged connection user, `podman_container` couldn't see the root-owned container at all, so `state: absent` silently no-op'd ("ok", no error, no change) instead of failing loudly. A clean "ok" status on a podman task is not proof the container was actually inspected — verify `become` is present when a delete/stop task looks suspiciously too easy.
- **`delete-backup-target.yml` was dropped from `maint/6.2`**: `dataplane-scripts/ansible-roles/trilio-datamover/tasks/delete-backup-target.yml` exists on `maint/6.1` but not on `maint/6.2`, since 6.2 stopped managing backup targets via these devops scripts. Jiras reported against this file must be fixed on `maint/6.1` — don't assume the "6.2.1 Jiras go to maint/6.2" branching convention applies when the affected file doesn't exist there.

## T4O Installation Guide
https://docs.trilio.io/openstack/deployment/installing-on-rhosp/trilio_installation_on_rhoso
