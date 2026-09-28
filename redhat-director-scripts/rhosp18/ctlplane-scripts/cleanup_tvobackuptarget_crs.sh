#!/bin/bash

set -e

NAMESPACE="trilio-openstack"
BT_CRD="tvobackuptargets.tvo.trilio.io"
MODE="list"

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }

usage() {
  echo "Usage: bash $(basename "$0") [--list | --delete]"
  echo "  --list    Show TVOBackupTarget CRD, CRs and their Helm release secrets (default, read-only)"
  echo "  --delete  Back up and delete all TVOBackupTarget CRs, their Helm release secrets and the CRD"
}

case "${1:-}" in
  ""|--list) MODE="list" ;;
  --delete)  MODE="delete" ;;
  -h|--help) usage; exit 0 ;;
  *)         usage; exit 1 ;;
esac

list_resources() {
  log_step "TVOBackupTarget resources in namespace ${NAMESPACE}"
  if ! oc get crd "${BT_CRD}" &>/dev/null; then
    log "CRD ${BT_CRD} not found."
    return 1
  fi
  log "CRD ${BT_CRD} exists."
  echo
  oc -n "${NAMESPACE}" get tvobackuptarget \
    -o custom-columns=NAME:.metadata.name,FINALIZERS:.metadata.finalizers,AGE:.metadata.creationTimestamp \
    2>/dev/null || true
  echo
  log "Helm release secrets:"
  for cr in $(oc -n "${NAMESPACE}" get tvobackuptarget -o name 2>/dev/null); do
    oc -n "${NAMESPACE}" get secrets -l "owner=helm,name=${cr##*/}" -o name 2>/dev/null
  done
  return 0
}

if [ "${MODE}" = "list" ]; then
  list_resources || log "Nothing to clean up."
  exit 0
fi

if ! list_resources; then
  log "Nothing to clean up."
  exit 0
fi

log_step "Back up TVOBackupTarget CRs"
BACKUP_FILE="tvobackuptarget-backup-$(date '+%Y%m%d-%H%M%S').yaml"
oc -n "${NAMESPACE}" get tvobackuptarget -o yaml > "${BACKUP_FILE}"
log "Saved: ${BACKUP_FILE}"

log_step "Delete TVOBackupTarget CRs and Helm release secrets"
bt_crs=$(oc -n "${NAMESPACE}" get tvobackuptarget -o name 2>/dev/null || true)
if [ -n "${bt_crs}" ]; then
  for cr in ${bt_crs}; do
    cr_name="${cr##*/}"
    oc -n "${NAMESPACE}" patch "${cr}" --type=merge -p '{"metadata":{"finalizers":null}}'
    oc -n "${NAMESPACE}" delete "${cr}" --ignore-not-found --wait=false
    oc -n "${NAMESPACE}" delete secret -l "owner=helm,name=${cr_name}" --ignore-not-found
    log "  Deleted TVOBackupTarget: ${cr_name}"
  done
else
  log "  No TVOBackupTarget CRs found."
fi

log_step "Delete CRD ${BT_CRD}"
oc delete crd "${BT_CRD}" --ignore-not-found
log "Deleted."

log_step "Verify"
if oc get crd "${BT_CRD}" &>/dev/null; then
  log "ERROR: CRD ${BT_CRD} still exists."
  exit 1
fi
leftover=""
for cr in ${bt_crs}; do
  s=$(oc -n "${NAMESPACE}" get secrets -l "owner=helm,name=${cr##*/}" -o name 2>/dev/null || true)
  [ -n "${s}" ] && leftover="${leftover}${s}"$'
'
done
if [ -n "${leftover}" ]; then
  log "ERROR: Helm release secrets still present:"
  echo "${leftover}"
  exit 1
fi
log "All TVOBackupTarget CRs, Helm release secrets and the CRD are removed."
