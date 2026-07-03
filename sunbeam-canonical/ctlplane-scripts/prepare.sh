#!/bin/bash
# prepare.sh
#
# Prepares the environment for T4O control plane installation:
#   1. Install Helm CLI (skipped if already installed)
#   2. Create trilio-openstack namespace and label control plane nodes
#      (skips nodes already labeled triliovault-control-plane=enabled)
#
# Usage:
#   bash prepare.sh [--helm-version <VERSION>] [--node-count <N>]
#
# Options:
#   --helm-version   Helm version to install (default: 3.17.2)
#   --node-count     Number of control plane nodes to label (default: 3)
#   -h, --help       Show this help and exit

set -euo pipefail

NAMESPACE="trilio-openstack"
HELM_VERSION="3.17.2"
NODE_COUNT=3

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --helm-version)  HELM_VERSION="$2"; shift 2 ;;
        --node-count)    NODE_COUNT="$2";   shift 2 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

echo "=================================================="
echo " T4O Control Plane — Prepare Environment"
echo " Namespace  : $NAMESPACE"
echo " Node count : $NODE_COUNT"
echo "=================================================="

# ---------- Step 1: Install Helm CLI ----------

echo ""
info "Step 1: Install Helm CLI"

if command -v helm &>/dev/null; then
    info "Helm already installed ($(helm version --short 2>/dev/null)) — skipping."
else
    info "Installing Helm ${HELM_VERSION}..."
    TARBALL="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
    curl -fsSL -O "https://get.helm.sh/${TARBALL}"
    tar -zxf "$TARBALL"
    sudo mv linux-amd64/helm /usr/local/bin/helm
    rm -rf linux-amd64 "$TARBALL"
    info "Helm $(helm version --short) installed."
fi

# ---------- Step 2: Create namespace and label control plane nodes ----------

echo ""
info "Step 2: Create namespace and label control plane nodes"

if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    info "Namespace '$NAMESPACE' already exists."
else
    kubectl create namespace "$NAMESPACE"
    info "Namespace '$NAMESPACE' created."
fi

ALREADY_COUNT=$(kubectl get nodes -l triliovault-control-plane=enabled \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$ALREADY_COUNT" -ge "$NODE_COUNT" ]; then
    info "${ALREADY_COUNT} node(s) already labeled triliovault-control-plane=enabled — skipping."
else
    NEEDED=$(( NODE_COUNT - ALREADY_COUNT ))
    info "${ALREADY_COUNT} node(s) already labeled. Labeling ${NEEDED} more..."

    CANDIDATES=$(kubectl get nodes -l openstack-control-plane=enabled \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    [ -n "$CANDIDATES" ] || err "No nodes found with openstack-control-plane=enabled. Is Sunbeam running?"

    LABELED=0
    for NODE in $CANDIDATES; do
        [ $LABELED -ge $NEEDED ] && break
        EXISTING=$(kubectl get node "$NODE" \
            -o jsonpath='{.metadata.labels.triliovault-control-plane}' 2>/dev/null || echo "")
        [ "$EXISTING" = "enabled" ] && continue
        kubectl label node "$NODE" triliovault-control-plane=enabled
        info "Labeled: $NODE"
        LABELED=$(( LABELED + 1 ))
    done
fi

TOTAL=$(kubectl get nodes -l triliovault-control-plane=enabled \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "triliovault-control-plane=enabled nodes: ${TOTAL}"

echo ""
echo "=================================================="
info "Done. Next steps:"
echo "  bash deploy_infra.sh"
echo "  bash generate_overrides.sh"
echo "=================================================="
