#!/bin/bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-trilio-openstack}"
RELEASE_NAME="${RELEASE_NAME:-tvo}"

echo "=== T4O Control Plane Uninstall ==="
echo "  Namespace : ${NAMESPACE}"
echo "  Release   : ${RELEASE_NAME}"
echo ""
read -rp "This will remove all T4O control plane services. Continue? [y/N] " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }

# Uninstall the Helm release
if helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" &>/dev/null; then
    helm uninstall "${RELEASE_NAME}" --namespace "${NAMESPACE}"
    echo "Helm release ${RELEASE_NAME} removed."
else
    echo "Helm release ${RELEASE_NAME} not found in namespace ${NAMESPACE}."
fi

# Optionally delete namespace
read -rp "Delete namespace ${NAMESPACE}? [y/N] " del_ns
if [[ "$del_ns" =~ ^[yY]$ ]]; then
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found
    echo "Namespace ${NAMESPACE} deleted."
fi

echo ""
echo "=== T4O Control Plane Uninstalled ==="
