#!/bin/bash
# deploy_tvo_control_plane.sh
#
# Single-script automation for T4O control plane installation on Sunbeam.
# Runs Steps 1-4 of the install process end-to-end:
#   1. Install Helm CLI (skipped if already installed)
#   2. Create trilio-openstack namespace and label 3 control plane nodes
#      (skips nodes already labeled with triliovault-control-plane=enabled)
#   3. Deploy infrastructure — MySQL InnoDB Cluster + RabbitMQ cluster
#   4. Generate overrides.yaml from cluster secrets
#
# After this script completes, review overrides.yaml for any manual params
# (registry auth, image tags) then run Step 5:
#   helm upgrade --install tvo helm-charts/tvo-chart \
#     --namespace trilio-openstack --values overrides.yaml --wait --timeout 15m
#
# Usage:
#   bash deploy_tvo_control_plane.sh [--helm-version <VERSION>] [--node-count <N>]
#
# Options:
#   --helm-version   Helm version to install (default: 3.17.2)
#   --node-count     Number of control plane nodes to label (default: 3)
#   -h, --help       Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="trilio-openstack"
HELM_VERSION="3.17.2"
NODE_COUNT=3

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${CYAN}========================================${NC}"; echo -e "${CYAN} $*${NC}"; echo -e "${CYAN}========================================${NC}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --helm-version)  HELM_VERSION="$2"; shift 2 ;;
        --node-count)    NODE_COUNT="$2";   shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

echo ""
echo "=================================================="
echo " T4O Control Plane — Full Install"
echo " Namespace  : $NAMESPACE"
echo " Node count : $NODE_COUNT control plane nodes will be labeled"
echo "=================================================="

# ---------- Step 1: Install Helm CLI ----------

step "Step 1: Install Helm CLI"

if command -v helm &>/dev/null; then
    INSTALLED_VER=$(helm version --short 2>/dev/null | grep -oP 'v\K[0-9.]+' | head -1 || echo "unknown")
    info "Helm already installed (version: ${INSTALLED_VER}) — skipping download."
else
    info "Installing Helm ${HELM_VERSION}..."
    ARCH="linux-amd64"
    TARBALL="helm-v${HELM_VERSION}-${ARCH}.tar.gz"
    curl -fsSL -O "https://get.helm.sh/${TARBALL}"
    tar -zxf "$TARBALL"
    sudo mv "${ARCH}/helm" /usr/local/bin/helm
    rm -rf "$ARCH" "$TARBALL"
    info "Helm $(helm version --short) installed."
fi

# ---------- Step 2: Create namespace and label control plane nodes ----------

step "Step 2: Create namespace and label control plane nodes"

if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    info "Namespace '$NAMESPACE' already exists."
else
    kubectl create namespace "$NAMESPACE"
    info "Namespace '$NAMESPACE' created."
fi

# Count nodes already carrying the triliovault label
ALREADY_COUNT=$(kubectl get nodes -l triliovault-control-plane=enabled \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "$ALREADY_COUNT" -ge "$NODE_COUNT" ]; then
    info "${ALREADY_COUNT} node(s) already labeled triliovault-control-plane=enabled — skipping labeling."
    kubectl get nodes -l triliovault-control-plane=enabled --no-headers \
        | awk '{print "  " $1}' || true
else
    NEEDED=$(( NODE_COUNT - ALREADY_COUNT ))
    info "${ALREADY_COUNT} node(s) already labeled. Labeling ${NEEDED} more from openstack-control-plane=enabled pool..."

    CANDIDATES=$(kubectl get nodes -l openstack-control-plane=enabled \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    [ -n "$CANDIDATES" ] || err "No nodes found with label openstack-control-plane=enabled. Is Sunbeam running?"

    LABELED=0
    for NODE in $CANDIDATES; do
        [ $LABELED -ge $NEEDED ] && break
        EXISTING=$(kubectl get node "$NODE" \
            -o jsonpath='{.metadata.labels.triliovault-control-plane}' 2>/dev/null || echo "")
        if [ "$EXISTING" = "enabled" ]; then
            continue
        fi
        kubectl label node "$NODE" triliovault-control-plane=enabled
        info "Labeled node: $NODE"
        LABELED=$(( LABELED + 1 ))
    done

    TOTAL=$(kubectl get nodes -l triliovault-control-plane=enabled \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    info "Total triliovault-control-plane=enabled nodes: ${TOTAL}"
fi

# ---------- Step 3: Deploy infrastructure ----------

step "Step 3: Deploy Infrastructure (MySQL InnoDB Cluster + RabbitMQ)"

bash "${SCRIPT_DIR}/utils/deploy_infra.sh"

# ---------- Step 4: Generate overrides.yaml ----------

step "Step 4: Generate overrides.yaml"

bash "${SCRIPT_DIR}/utils/generate_overrides.sh"

# ---------- Summary ----------

echo ""
echo "=================================================="
info "Steps 1-4 complete."
echo ""
warn "Review overrides.yaml before proceeding to Step 5:"
echo "  - Set images.trilio_container_registry_login_enabled: true"
echo "    and provide registry_url/username/password if using a private registry."
echo "  - Update image tags if this is a new T4O release."
echo ""
echo "  Then run Step 5 (install T4O):"
echo ""
echo "    helm upgrade --install tvo \\"
echo "      helm-charts/tvo-chart \\"
echo "      --namespace trilio-openstack \\"
echo "      --values overrides.yaml \\"
echo "      --wait --timeout 15m"
echo "=================================================="
