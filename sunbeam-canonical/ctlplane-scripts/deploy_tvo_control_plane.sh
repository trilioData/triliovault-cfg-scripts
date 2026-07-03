#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm-charts/tvo-chart"
NAMESPACE="${NAMESPACE:-trilio-openstack}"
RELEASE_NAME="${RELEASE_NAME:-tvo}"
VALUES_FILE="${VALUES_FILE:-${CHART_DIR}/values.yaml}"

usage() {
    echo "Usage: $0 [-n NAMESPACE] [-f VALUES_FILE] [install|upgrade]"
    echo ""
    echo "  install   Fresh install of T4O control plane (default)"
    echo "  upgrade   Upgrade existing T4O control plane"
    echo ""
    echo "Environment variables:"
    echo "  NAMESPACE     Kubernetes namespace (default: trilio-openstack)"
    echo "  RELEASE_NAME  Helm release name (default: tvo)"
    echo "  VALUES_FILE   Path to custom values file"
    exit 1
}

COMMAND="${1:-install}"

if [[ "$COMMAND" != "install" && "$COMMAND" != "upgrade" ]]; then
    usage
fi

# Verify prerequisites
for cmd in kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Please install it first."
        exit 1
    fi
done

echo "=== T4O Control Plane ${COMMAND^} ==="
echo "  Namespace   : ${NAMESPACE}"
echo "  Release     : ${RELEASE_NAME}"
echo "  Chart       : ${CHART_DIR}"
echo "  Values file : ${VALUES_FILE}"
echo ""

# Create namespace if it doesn't exist
kubectl get namespace "${NAMESPACE}" &>/dev/null || \
    kubectl create namespace "${NAMESPACE}"

if [[ "$COMMAND" == "install" ]]; then
    helm install "${RELEASE_NAME}" "${CHART_DIR}" \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --wait \
        --timeout 10m \
        --debug

    echo ""
    echo "=== T4O Control Plane Installed Successfully ==="
    echo "Run the following to check pod status:"
    echo "  kubectl get pods -n ${NAMESPACE}"

elif [[ "$COMMAND" == "upgrade" ]]; then
    helm upgrade "${RELEASE_NAME}" "${CHART_DIR}" \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --wait \
        --timeout 10m \
        --debug

    echo ""
    echo "=== T4O Control Plane Upgraded Successfully ==="
    echo "Run the following to check pod status:"
    echo "  kubectl get pods -n ${NAMESPACE}"
fi
