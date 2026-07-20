#!/bin/bash
# TVAULT-7493 migration: delete the old (trilio-galera-cluster) Galera CR,
# wait for its pods to terminate, then delete its three PVCs after confirming
# their PVs are set to Retain. Does NOT touch the new (trilio-db-cluster)
# CR/PVCs/PVs.
#
# Prerequisite: run pause_operator_and_retain_old_pvs.sh first so the operator
# is paused and these PVs are already set to Retain.
set -euo pipefail

APP_NAMESPACE="trilio-openstack"
OLD_CR="trilio-galera-cluster"
REPLICAS=3

echo "==> Checking whether the old Galera CR ($OLD_CR) still exists..."
if oc get galera "$OLD_CR" -n "$APP_NAMESPACE" >/dev/null 2>&1; then
  echo "    Deleting CR $OLD_CR..."
  oc delete galera "$OLD_CR" -n "$APP_NAMESPACE"

  echo "    Waiting for its pods to terminate..."
  for i in $(seq 1 30); do
    PODCOUNT=$(oc get pods -n "$APP_NAMESPACE" -l "cr=galera-${OLD_CR}" --no-headers 2>/dev/null | wc -l)
    if [ "$PODCOUNT" -eq 0 ]; then
      echo "    OK: all $OLD_CR pods are gone."
      break
    fi
    echo "    Still waiting... ($PODCOUNT pod(s) remaining)"
    sleep 5
    if [ "$i" -eq 30 ]; then
      echo "ERROR: pods for $OLD_CR did not terminate within 150s. Aborting before touching PVCs." >&2
      exit 1
    fi
  done
else
  echo "    OK: CR $OLD_CR not found (already deleted or never existed here)."
fi

echo ""
echo "==> Safety check: confirming reclaim policy is Retain on all $REPLICAS old PVs before deleting anything..."
for i in $(seq 0 $((REPLICAS - 1))); do
  PVC="mysql-db-${OLD_CR}-galera-${i}"
  PV=$(oc get pvc "$PVC" -n "$APP_NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
  if [ -z "$PV" ]; then
    echo "    WARNING: PVC $PVC not found, skipping." >&2
    continue
  fi
  POLICY=$(oc get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
  if [ "$POLICY" != "Retain" ]; then
    echo "ERROR: PV $PV (behind $PVC) has reclaimPolicy=$POLICY, not Retain. Aborting — deleting this PVC would destroy the PV and its data." >&2
    echo "        Run pause_operator_and_retain_old_pvs.sh first, or patch it manually:" >&2
    echo "        oc patch pv $PV -p '{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}'" >&2
    exit 1
  fi
  echo "    OK: $PVC -> PV=$PV reclaimPolicy=Retain"
done

echo ""
echo "==> Deleting the $REPLICAS old PVCs..."
for i in $(seq 0 $((REPLICAS - 1))); do
  PVC="mysql-db-${OLD_CR}-galera-${i}"
  if oc get pvc "$PVC" -n "$APP_NAMESPACE" >/dev/null 2>&1; then
    oc delete pvc "$PVC" -n "$APP_NAMESPACE"
  else
    echo "    WARNING: PVC $PVC already gone, skipping." >&2
  fi
done

echo ""
echo "==> Verifying the PVs are still there after the PVCs got deleted (expect status=Released, not gone):"
oc get pv | grep trilio | grep galera

echo ""
echo "==> Done. Old PVCs deleted; their PVs should be Released above (data intact) and still exist."
echo "==> Next step: clear claimRef on these PVs so they can be bound to the new PVCs (not done by this script)."
