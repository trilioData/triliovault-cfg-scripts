#!/bin/bash
# TVAULT-7493 migration prep: pause the TVO operator, then set reclaim policy
# to Retain on the OLD (trilio-galera-cluster) Galera PVs only. Does NOT touch
# the new (trilio-db-cluster) PVCs/PVs.
set -euo pipefail

OPERATOR_NAMESPACE="tvo-operator-system"
OPERATOR_DEPLOYMENT="tvo-operator-controller-manager"
APP_NAMESPACE="trilio-openstack"
OLD_CR="trilio-galera-cluster"
REPLICAS=3

echo "==> Scaling down $OPERATOR_DEPLOYMENT in $OPERATOR_NAMESPACE to 0 replicas..."
oc scale deployment "$OPERATOR_DEPLOYMENT" -n "$OPERATOR_NAMESPACE" --replicas=0

echo "==> Waiting for operator pod(s) to terminate..."
for i in $(seq 1 30); do
  READY=$(oc get deployment "$OPERATOR_DEPLOYMENT" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  PODCOUNT=$(oc get pods -n "$OPERATOR_NAMESPACE" -l control-plane=controller-manager --no-headers 2>/dev/null | wc -l)
  if [ -z "$READY" ] && [ "$PODCOUNT" -eq 0 ]; then
    echo "    Operator is fully scaled down (0 pods running)."
    break
  fi
  echo "    Still waiting... (readyReplicas=${READY:-0}, pods running=$PODCOUNT)"
  sleep 5
  if [ "$i" -eq 30 ]; then
    echo "ERROR: operator did not scale down within 150s. Aborting before touching PVs." >&2
    exit 1
  fi
done

echo ""
echo "==> Verifying deployment state:"
oc get deployment "$OPERATOR_DEPLOYMENT" -n "$OPERATOR_NAMESPACE"
oc get pods -n "$OPERATOR_NAMESPACE"

echo ""
echo "==> Setting reclaim policy to Retain on the OLD ($OLD_CR) PVs only..."
for i in $(seq 0 $((REPLICAS - 1))); do
  PVC="mysql-db-${OLD_CR}-galera-${i}"
  PV=$(oc get pvc "$PVC" -n "$APP_NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
  if [ -z "$PV" ]; then
    echo "    WARNING: PVC $PVC not found in $APP_NAMESPACE, skipping." >&2
    continue
  fi
  CURRENT_POLICY=$(oc get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
  echo "    $PVC -> PV=$PV (current policy: $CURRENT_POLICY)"
  oc patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
  NEW_POLICY=$(oc get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
  echo "    $PVC -> PV=$PV patched, policy now: $NEW_POLICY"
  if [ "$NEW_POLICY" != "Retain" ]; then
    echo "ERROR: patch did not take effect for PV $PV (still $NEW_POLICY)." >&2
    exit 1
  fi
done

echo ""
echo "==> Final verification: re-checking all $REPLICAS old-cluster PVs report Retain..."
FAILED=0
for i in $(seq 0 $((REPLICAS - 1))); do
  PVC="mysql-db-${OLD_CR}-galera-${i}"
  PV=$(oc get pvc "$PVC" -n "$APP_NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
  if [ -z "$PV" ]; then
    echo "    FAIL: PVC $PVC not found, cannot verify." >&2
    FAILED=1
    continue
  fi
  POLICY=$(oc get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
  if [ "$POLICY" = "Retain" ]; then
    echo "    OK:   $PVC -> PV=$PV reclaimPolicy=$POLICY"
  else
    echo "    FAIL: $PVC -> PV=$PV reclaimPolicy=$POLICY (expected Retain)" >&2
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "ERROR: one or more old-cluster PVs are NOT set to Retain. Do not proceed with deleting any PVCs until this is fixed." >&2
  exit 1
fi

echo ""
echo "==> Done. Operator is paused (0 replicas) and old-cluster PVs are protected (Retain)."
echo "==> New-cluster (trilio-db-cluster) PVCs/PVs were NOT touched."
