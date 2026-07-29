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
- **Never make a stateful/identity-bearing CR a Helm hook without a delete-policy (TVAULT-7517)**: `rabbitmq-cluster.yaml` (both chart variants) used to be tagged `helm.sh/hook: post-install,post-upgrade` with no `hook-delete-policy`. Helm's *documented default* for an unset `hook-delete-policy` is `before-hook-creation` - it deletes the existing hook resource and recreates it fresh on **every** hook firing, i.e. on every single `helm upgrade`, not just the first install. Since the RabbitMQ operator (community `RabbitmqCluster` or native `RabbitMq`, either one) auto-generates a random `default-user` secret whenever the CR object is created, this meant **any** subsequent `oc apply` of `tvo-operator-inputs.yaml` - even one that never touched a rabbitmq field - deleted and recreated the RabbitMQ CR, minting a fresh secret while the StatefulSet's PVCs kept the old Mnesia data/credentials, breaking datamover-api/wlm auth. Confirmed via CR/secret UID and creationTimestamp changing across an unrelated second apply. Occasionally this also raced with the object's own finalizer-driven deletion and failed the hook outright (`object is being deleted: rabbitmqs.rabbitmq.openstack.org "trilio-rabbitmq-cluster" already exists`), rolling back the whole release - same root cause, just the failure-mode half of it. Fixed by removing the hook annotations entirely so the CR is a normal templated resource (Helm patches it in place across upgrades, like any Deployment/StatefulSet, instead of delete+recreate) - see PRs #1543 (maint/6.1) / #1544 (maint/6.2). General lesson: don't tag a CR as a Helm hook if its controller mints persistent, randomly-generated state (secrets, tokens) on creation - hooks are for one-shot side effects (Jobs), not for anything that needs to survive across upgrades with stable identity.
- **Release image tags**: `https://docs.trilio.io/openstack/about-trilio-for-openstack/artifacts/<version>` (e.g. `.../6.1.9`) lists the exact published image URLs/tags for that T4O release — check here rather than guessing tag strings when testing/upgrading against a real release.
- **`dmapi`/`workloadmgr` RabbitMQ credentials are independent of the RabbitMQ CR's lifecycle**: the `dmapi` user's password is a fixed value in `trilio-openstack-secret` (`DmapiRabbitPassword`), not derived from the cluster's own auto-generated `<name>-default-user` secret. This means datamover's connection config never needs to change across a RabbitMQ CR recreate — the rabbitmq-init hook Jobs re-declare the same fixed-password users against the new broker, and datamover's own AMQP client auto-reconnects and redeclares its queues/exchanges without needing a restart or redeploy. Confirmed via a genuine operator-image upgrade test (real 6.1.9 GA operator → fix operator, RabbitMQ CR+PVCs deleted/recreated by the upgrade) with datamover left running untouched the entire time — a real backup completed successfully afterward.
- **Always validate hook/upgrade behavior with a genuine operator image swap, not a CR-spec toggle.** Confirmed via a full real-upgrade test (uninstall everything → install the actual unmodified 6.1.9 GA operator → in-place image swap to the fix build, no CR/spec changes) that a real operator upgrade correctly and automatically re-runs every Helm hook Job on its own, including both rabbitmq-init Jobs — no manual Job deletion or `hook-delete-policy` change needed anywhere in the chart. Forcing a Helm reconcile by patching an unrelated CR spec field instead of swapping the operator image does not reliably exercise the same hook re-execution path, so it's not a valid way to test upgrade/hook behavior.

## Known Constraints
- **`workloadmgr backup-target-list --format json` mixes target types**: the output includes a `Type` field (`"s3"` / `"nfs"`, compare case-insensitively) alongside `Backend Endpoint` and `ID`. For S3, `Backend Endpoint` is a plain bucket name or `host:port/bucket` (take the last `/`-separated component). For NFS, `Backend Endpoint` is the share path itself (e.g. `host:/export`) — do **not** split on `/`, that truncates the path into a false identifier (this caused TVAULT-7419's phantom bucket-name mismatch). Confirmed against the same CLI schema in `juju-charms/upgrade_backup_targets_62.sh`.
- **T4O 6.0/6.1 NFS backup target field names** (`tvo-operator-inputs.yaml` `spec.triliovault_backup_targets[]` and `TVOBackupTarget` CR `spec.triliovault_backup_target`): `backup_target_type: 'nfs'`, `nfs_shares` (export path, e.g. `'192.168.2.3:/nfs/share'`), `nfs_options` (mount options string). Parallel to the `s3_*` fields already used for S3 targets. These aren't documented anywhere in the `maint/6.2` tree — the CRD (`tvo.trilio.io_tvobackuptargets.yaml`) and sample CR templates (`tvo-backup-target-cr-nfs.yaml`, `tvo-backup-target-cr-*-s3.yaml`) only exist on `maint/6.1`; they were dropped before `maint/6.2` since 6.2 stopped managing backup targets via devops scripts. Check `git show maint/6.1:redhat-director-scripts/rhosp18/ctlplane-scripts/<file>` when you need the real schema.
- **NFS backup targets need no Barbican secret in the 6.1→6.2 migration**: `update_backup_targets_62.sh` intentionally skips NFS entries — only S3 credential storage moves from k8s Secrets to Barbican in 6.2; NFS backup target records are unchanged. This is documented behavior (see the Confluence page "T4O 6.2 Install and Upgrade Step Changes For RHOSO18"), not a bug — don't try to add Barbican secret creation for NFS there.

## T4O Installation Guide
https://docs.trilio.io/openstack/deployment/installing-on-rhosp/trilio_installation_on_rhoso
