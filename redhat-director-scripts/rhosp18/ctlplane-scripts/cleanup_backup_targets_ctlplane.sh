#!/bin/bash
# cleanup_backup_targets_ctlplane.sh
#
# Cleans up backup target remnants on RHOSO18 control plane nodes
# (trilio-control-plane=enabled) after upgrading T4O 6.0/6.1 to 6.2.
#
# What it does:
#   1. Delete old object store DaemonSets (stops S3 FUSE pods so they cannot remount)
#   2. Delete old NFS mount DaemonSets (stops NFS pods so they cannot remount)
#   3. Wait for all old pods to fully terminate
#   4. Deploy a privileged cleanup DaemonSet to lazy-unmount any hung FUSE/NFS
#      mount points left behind on the host after pod termination
#   5. Wait for cleanup to complete on every control plane node
#   6. Delete the cleanup DaemonSet
#   7. Remove remaining orphaned K8s resources from the 6.1 object store
#
# Ordering matters: old pods must be gone before unmounting. If the pods are
# still running when we unmount, they will immediately remount.
#
# Run AFTER T4O 6.2 is deployed.
#
# Usage:
#   bash cleanup_backup_targets_ctlplane.sh
#
# Prerequisites:
#   - oc CLI authenticated with cluster-admin or appropriate RBAC
#   - trilio-openstack namespace exists with triliovault-wlm service account

set -e

NAMESPACE="trilio-openstack"
CLEANUP_DS="trilio-ctlplane-bt-cleanup"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_YAML="${SCRIPT_DIR}/trilio-ctlplane-backup-target-cleanup.yaml"
POD_TERM_TIMEOUT=120   # seconds to wait for old pods to terminate
CLEANUP_TIMEOUT=300    # seconds to wait for cleanup DaemonSet pods to be ready

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }

log_step "T4O Control Plane Backup Target Cleanup"
log "Namespace      : ${NAMESPACE}"
log "Term timeout   : ${POD_TERM_TIMEOUT}s"
log "Cleanup timeout: ${CLEANUP_TIMEOUT}s"

# -----------------------------------------------------------------------
# Step 1: Delete orphaned S3 object store DaemonSets.
#         Must happen BEFORE unmounting — running pods remount immediately
#         if we unmount while they are still alive.
#         Naming pattern from 6.1: triliovault-object-store-<bt-name>
# -----------------------------------------------------------------------
log_step "Step 1: Delete orphaned object store DaemonSets"
obj_ds=$(oc -n "${NAMESPACE}" get daemonsets -o name 2>/dev/null \
  | grep "triliovault-object-store" || true)
if [ -n "${obj_ds}" ]; then
  echo "${obj_ds}" | xargs -r oc -n "${NAMESPACE}" delete
  log "Deleted: $(echo "${obj_ds}" | tr '\n' ' ')"
else
  log "None found."
fi

# -----------------------------------------------------------------------
# Step 2: Delete orphaned NFS mount DaemonSets.
#         Naming pattern from 6.1: triliovault-nfs-mount-<bt-name>
# -----------------------------------------------------------------------
log_step "Step 2: Delete orphaned NFS mount DaemonSets"
nfs_ds=$(oc -n "${NAMESPACE}" get daemonsets -o name 2>/dev/null \
  | grep "triliovault-nfs-mount" || true)
if [ -n "${nfs_ds}" ]; then
  echo "${nfs_ds}" | xargs -r oc -n "${NAMESPACE}" delete
  log "Deleted: $(echo "${nfs_ds}" | tr '\n' ' ')"
else
  log "None found."
fi

# -----------------------------------------------------------------------
# Step 3: Wait for old object store and NFS pods to fully terminate.
#         Pods may take time to complete their preStop lifecycle hooks.
#         We must wait until no such pods remain before unmounting.
# -----------------------------------------------------------------------
log_step "Step 3: Wait for old pods to terminate"
elapsed=0
while true; do
  remaining_pods=$(oc -n "${NAMESPACE}" get pods -o name 2>/dev/null \
    | grep -E "triliovault-object-store|triliovault-nfs-mount" || true)
  if [ -z "${remaining_pods}" ]; then
    log "All old backup target pods have terminated."
    break
  fi
  log "Waiting for pods to terminate (${elapsed}s elapsed):"
  echo "${remaining_pods}" | while read -r p; do log "  ${p}"; done
  if [ "${elapsed}" -ge "${POD_TERM_TIMEOUT}" ]; then
    log "WARNING: Some pods did not terminate within ${POD_TERM_TIMEOUT}s."
    log "Proceeding — remaining pods may cause mounts to re-appear after cleanup."
    log "Check manually: oc -n ${NAMESPACE} get pods"
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

# -----------------------------------------------------------------------
# Step 4: Deploy cleanup DaemonSet to unmount any hung FUSE/NFS mount
#         points left on trilio-control-plane=enabled nodes. Safe to run
#         now that the old pods are gone and cannot remount.
# -----------------------------------------------------------------------
log_step "Step 4: Deploy cleanup DaemonSet to unmount hung mount points"
oc -n "${NAMESPACE}" apply -f "${CLEANUP_YAML}"

# -----------------------------------------------------------------------
# Step 5: Wait for all cleanup pods to reach Running state (cleanup script
#         runs to completion then sleeps, so Running = work is done).
# -----------------------------------------------------------------------
log_step "Step 5: Wait for cleanup pods to complete"
desired=$(oc -n "${NAMESPACE}" get daemonset "${CLEANUP_DS}" \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")

if [ "${desired}" -eq 0 ]; then
  log "WARNING: No nodes with trilio-control-plane=enabled found. Nothing to unmount."
else
  log "Cleanup pods expected: ${desired}"
  elapsed=0
  while true; do
    ready=$(oc -n "${NAMESPACE}" get daemonset "${CLEANUP_DS}" \
      -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    log "Pods ready: ${ready}/${desired}  (${elapsed}s elapsed)"
    [ "${ready}" -eq "${desired}" ] && break
    if [ "${elapsed}" -ge "${CLEANUP_TIMEOUT}" ]; then
      log "ERROR: Timed out waiting for cleanup pods after ${CLEANUP_TIMEOUT}s."
      log "Check logs: oc -n ${NAMESPACE} logs -l component=ctlplane-bt-cleanup"
      exit 1
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done

  log "All cleanup pods ready. Verifying completion per node:"
  for pod in $(oc -n "${NAMESPACE}" get pods \
      -l "component=ctlplane-bt-cleanup" \
      -o jsonpath='{.items[*].metadata.name}'); do
    node=$(oc -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')
    if oc -n "${NAMESPACE}" logs "${pod}" 2>/dev/null \
        | grep -q "CTLPLANE_CLEANUP_DONE"; then
      log "  [OK]   ${pod}  (node: ${node})"
    else
      log "  [WARN] ${pod}  (node: ${node}) -- CTLPLANE_CLEANUP_DONE not found in logs"
    fi
  done
fi

# -----------------------------------------------------------------------
# Step 6: Delete the cleanup DaemonSet.
# -----------------------------------------------------------------------
log_step "Step 6: Delete cleanup DaemonSet"
oc -n "${NAMESPACE}" delete daemonset "${CLEANUP_DS}" --ignore-not-found
log "Deleted."

# -----------------------------------------------------------------------
# Step 7: Remove remaining orphaned K8s resources from 6.1 object store.
# -----------------------------------------------------------------------
log_step "Step 7: Remove orphaned object store K8s resources"

delete_if_exists() {
  local kind=$1
  local name=$2
  if oc -n "${NAMESPACE}" get "${kind}" "${name}" &>/dev/null; then
    oc -n "${NAMESPACE}" delete "${kind}" "${name}"
    log "  Deleted ${kind}: ${name}"
  else
    log "  Not found (skip): ${kind}/${name}"
  fi
}

# Shared resources created by the multi-backup-target object store templates
delete_if_exists secret         triliovault-object-store-etc
delete_if_exists configmap      triliovault-object-store-bin
delete_if_exists serviceaccount triliovault-object-store
delete_if_exists role           default-triliovault-object-store
delete_if_exists rolebinding    default-triliovault-object-store

# Per-backup-target S3 secrets from single-backup-target mode
# Pattern: trilio-s3-backup-target-secret-<bt-name>
s3_secrets=$(oc -n "${NAMESPACE}" get secrets -o name 2>/dev/null \
  | grep "trilio-s3-backup-target-secret-" || true)
if [ -n "${s3_secrets}" ]; then
  echo "${s3_secrets}" | xargs -r oc -n "${NAMESPACE}" delete
  log "  Deleted S3 per-BT secrets: $(echo "${s3_secrets}" | tr '\n' ' ')"
else
  log "  No per-BT S3 secrets found."
fi

log_step "Control plane backup target cleanup complete"
