# Automated Upgrade Guide: T4O 5.2 / 6.1 to 6.2 (OpenStack-Helm)

## Overview
Upgrading to TrilioVault for OpenStack (T4O) 6.2 introduces the Dynamic Mount Service (DMS) and OpenStack Barbican integration, fundamentally changing how Backup Targets and credentials are mathematically stored and mounted.

To ensure zero data loss and a seamless transition from legacy architectures (either the static 5.2 Helm configs or the 6.1 K8s Secrets), we utilize a three-script automated upgrade workflow.

## Prerequisites
- `kubectl` configured with cluster-admin rights.
- Ensure all three automation scripts are executable in `openstack-helm/scripts/`:
  - `collect_backup_targets_osh.sh`
  - `migrate_backup_targets_osh.sh`
  - `cleanup_legacy_mounts_osh.sh`

---

## Step-by-Step Upgrade Process

### Step 1: Pre-Upgrade — Collect Backup Targets
**You must run this BEFORE upgrading your Helm release.**

This script safely extracts your existing backup target configurations. If you are on 5.2, it parses your active Helm values. If you are on 6.1, it queries the database and securely extracts S3 credentials from Kubernetes Secrets.

```bash
cd openstack-helm/
bash scripts/collect_backup_targets_osh.sh
```
> [!IMPORTANT]
> This generates `existing_backup_targets.json` in your current directory. **Do not delete this file**, as the post-upgrade script requires it!

### Step 2: Clean Up Helm Values
Modify your `values.yaml` and override files for the 6.2 deployment:
1. **Remove legacy overrides:** Do not pass `nfs.yaml` or `s3.yaml` overrides to the `helm upgrade` command.
2. **Prevent Race Conditions:** Ensure `manifests.job_wlm_cloud_trust: false` is set in your `values.yaml`.

### Step 3: Upgrade Helm Release
Upgrade the helm chart to 6.2 using your updated image tags and values.

```bash
helm upgrade trilio-openstack ./trilio-openstack \
  --namespace trilio-openstack \
  -f ./trilio-openstack/values.yaml \
  -f ./trilio-openstack/values_overrides/<your-6.2-release>.yaml
```
Wait for all pods to reach the `Running` state:
```bash
kubectl get pods -n trilio-openstack -w
```

### Step 4: Post-Upgrade — Clean Up Zombie Mounts
While Helm automatically deletes the old `triliovault-object-store` pods, the underlying host operating systems will still have stale mounts pointing to `/var/lib/trilio/triliovault-mounts/`.

Run the cleanup script. This deploys a temporary, self-destructing privileged Kubernetes DaemonSet to safely unmount and wipe the zombie directories across all control and compute nodes natively.

```bash
bash scripts/cleanup_legacy_mounts_osh.sh
```

### Step 5: Post-Upgrade — Migrate Backup Targets
Now that the 6.2 API is online and the old mounts are gone, run the migration script.

This script reads your `existing_backup_targets.json` file. For S3 targets, it automatically pushes the credentials securely to OpenStack Barbican via the WLM pod, and runs the necessary `workloadmgr` commands to recreate or modify your targets in the database.

```bash
bash scripts/migrate_backup_targets_osh.sh
```
Verify the script summary output to ensure all targets migrated successfully.

### Step 6: Post-Upgrade — Re-Initialize Cloud Admin Trust
> [!WARNING]
> Because Trust Creation uploads metadata to the storage backend, this step **MUST** happen after Step 5 (when the Backup Target is officially online).

Re-initialize the cloud trust object against the newly migrated Multi-Backup Target backend:

```bash
WLM_POD=$(kubectl get pods -n trilio-openstack -l component=wlm-api -o jsonpath="{.items[0].metadata.name}")
kubectl exec -it -n trilio-openstack $WLM_POD -- bash -c \
  "source /etc/triliovault-wlm/admin-openrc.sh && workloadmgr --insecure --os-endpoint-type internal trust-create --is_cloud_trust True admin"
```

### Step 7: Final Verification
Verify that your backup targets are in an `available` state and your trust is successfully listed.

```bash
kubectl exec -it -n trilio-openstack $WLM_POD -- bash -c \
  "source /etc/triliovault-wlm/admin-openrc.sh && workloadmgr --insecure backup-target-list && workloadmgr --insecure trust-list --get_hidden True"
```
Your TrilioVault 6.2 environment is now fully upgraded and operational!
