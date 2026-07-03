#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm-charts/tvo-chart"
NAMESPACE="${NAMESPACE:-trilio-openstack}"
RELEASE_NAME="${RELEASE_NAME:-tvo}"
VALUES_FILE="${VALUES_FILE:-${CHART_DIR}/values.yaml}"

usage() {
    echo "Usage: VALUES_FILE=my-values.yaml $0"
    echo ""
    echo "Upgrades the T4O control plane Helm release."
    echo "wlm-cron is scaled to 0 before DB migration and back to 1 after."
    echo ""
    echo "Environment variables:"
    echo "  NAMESPACE     Kubernetes namespace (default: trilio-openstack)"
    echo "  RELEASE_NAME  Helm release name (default: tvo)"
    echo "  VALUES_FILE   Path to custom values file (default: values.yaml)"
    exit 1
}

# Verify prerequisites
for cmd in kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Please install it first."
        exit 1
    fi
done

# Ensure a release already exists
if ! helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" &>/dev/null; then
    echo "ERROR: Helm release '${RELEASE_NAME}' not found in namespace '${NAMESPACE}'."
    echo "Run deploy_tvo_control_plane.sh install for a fresh installation."
    exit 1
fi

# Show current deployed version
CURRENT_VERSION=$(helm list --namespace "${NAMESPACE}" \
    --filter "^${RELEASE_NAME}$" -o json | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0]['app_version'] if r else 'unknown')" 2>/dev/null || echo "unknown")
TARGET_VERSION=$(grep '^appVersion:' "${CHART_DIR}/Chart.yaml" | awk '{print $2}')

echo "=== T4O Control Plane Upgrade ==="
echo "  Namespace      : ${NAMESPACE}"
echo "  Release        : ${RELEASE_NAME}"
echo "  Current version: ${CURRENT_VERSION}"
echo "  Target version : ${TARGET_VERSION}"
echo "  Values file    : ${VALUES_FILE}"
echo ""

read -rp "Proceed with upgrade? [y/N] " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }

# Step 1: Scale wlm-cron to 0 before upgrade.
# wlm-cron must not run while DB migrations execute — a cron pod reading a
# partially-migrated schema causes job state corruption.
echo ""
echo "[1/4] Pausing wlm-cron before DB migration..."
kubectl scale deployment/triliovault-wlm-cron \
    --replicas=0 \
    --namespace "${NAMESPACE}"
kubectl rollout status deployment/triliovault-wlm-cron \
    --namespace "${NAMESPACE}" \
    --timeout=120s || true
echo "  wlm-cron scaled to 0."

# Step 2: Run Helm upgrade — this triggers job-wlm-db-init hook
echo ""
echo "[2/4] Running helm upgrade..."
helm upgrade "${RELEASE_NAME}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 10m

# Step 3: Scale wlm-cron back to 1 after upgrade completes
echo ""
echo "[3/4] Resuming wlm-cron (restoring to replicas=1)..."
kubectl scale deployment/triliovault-wlm-cron \
    --replicas=1 \
    --namespace "${NAMESPACE}"
kubectl rollout status deployment/triliovault-wlm-cron \
    --namespace "${NAMESPACE}" \
    --timeout=120s
echo "  wlm-cron is running."

# Step 4: Post-upgrade verification
echo ""
echo "[4/4] Post-upgrade pod status:"
kubectl get pods --namespace "${NAMESPACE}" \
    -l application=triliovault \
    -o wide

NOT_RUNNING=$(kubectl get pods --namespace "${NAMESPACE}" \
    -l application=triliovault \
    --field-selector=status.phase!=Running \
    --no-headers 2>/dev/null | grep -v Completed || true)

if [[ -n "$NOT_RUNNING" ]]; then
    echo ""
    echo "WARNING: Some pods are not in Running state:"
    echo "$NOT_RUNNING"
    echo "Check logs with: kubectl logs -n ${NAMESPACE} <pod-name>"
    exit 1
fi

echo ""
echo "=== T4O Control Plane Upgraded Successfully: ${CURRENT_VERSION} -> ${TARGET_VERSION} ==="
