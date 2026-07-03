#!/bin/bash
# deploy_dataplane.sh
#
# Deploys T4O DataMover on all Sunbeam compute nodes by reading dataplane_inputs.yaml.
#
# Steps performed:
#   1. Auto-populate connectivity values (dmapi_transport_url, dmapi_database_connection,
#      keystone_auth_url) from K8s secrets into dataplane_inputs.yaml
#   2. Generate Ansible inventory (inventory.ini) from OpenStack hypervisors
#   3. Run ansible-playbook install_datamover.yml using dataplane_inputs.yaml as vars
#   4. Verify tvault-contego service is active on all nodes
#
# Prerequisites:
#   - deploy_ctlplane.sh has been run successfully (trilio-infra-passwords secret exists)
#   - dataplane_inputs.yaml reviewed and configured (images, registry auth, flags)
#   - Ansible installed (bash prepare.sh installs it)
#   - SSH access from this node to all compute nodes
#
# Usage:
#   bash deploy_dataplane.sh [--inputs-file dataplane_inputs.yaml] [--limit NODE]
#
# Options:
#   --inputs-file   Path to dataplane_inputs.yaml (default: same dir as this script)
#   --limit         Ansible --limit pattern (e.g. specific hostname)
#   -h, --help      Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATAPLANE_INPUTS="${SCRIPT_DIR}/dataplane_inputs.yaml"
DATAPLANE_SCRIPTS="${SCRIPT_DIR}/dataplane-scripts"
ANSIBLE_LIMIT=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)  DATAPLANE_INPUTS="$2"; shift 2 ;;
        --limit)        ANSIBLE_LIMIT="$2"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[ -f "$DATAPLANE_INPUTS" ] || err "dataplane_inputs.yaml not found: $DATAPLANE_INPUTS"

NAMESPACE="trilio-openstack"
INFRA_SECRET="trilio-infra-passwords"

echo "=================================================="
echo " T4O Sunbeam — Deploy Data Plane"
echo " Inputs    : $DATAPLANE_INPUTS"
echo "=================================================="

# ---------- Step 1: Auto-populate connectivity values ----------

step "Step 1: Auto-populating connectivity from cluster secrets..."

read_secret() {
    local key="$1"
    kubectl get secret "$INFRA_SECRET" -n "$NAMESPACE" \
        -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

# Verify infra secret exists
kubectl get secret "$INFRA_SECRET" -n "$NAMESPACE" &>/dev/null || \
    err "Secret '$INFRA_SECRET' not found in namespace '$NAMESPACE'. Run deploy_ctlplane.sh first."

DMAPI_RABBIT_PASSWORD=$(read_secret "rabbitmq-dmapi-password")
DMAPI_DB_PASSWORD=$(read_secret "mysql-dmapi-password")

# Auto-detect MicroK8s node IP
NODE_IP=$(kubectl get nodes -l openstack-control-plane=enabled \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "")
[ -n "$NODE_IP" ] && info "Node IP: $NODE_IP" || \
    warn "Could not auto-detect node IP. Connectivity values may need manual editing."

# Auto-detect Keystone URL
KEYSTONE_URL=""
if command -v sunbeam &>/dev/null; then
    OPENRC=$(sunbeam openrc 2>/dev/null || echo "")
    [ -n "$OPENRC" ] && eval "$OPENRC" 2>/dev/null || true
    KEYSTONE_URL="${OS_AUTH_URL:-}"
fi
if [ -z "$KEYSTONE_URL" ]; then
    KS_IP=$(kubectl -n openstack get service keystone-internal \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    [ -n "$KS_IP" ] && KEYSTONE_URL="http://${KS_IP}:5000/v3"
fi
[ -n "$KEYSTONE_URL" ] && info "Keystone URL: $KEYSTONE_URL"

# Build connection strings
TRANSPORT_URL="rabbit://dmapi:${DMAPI_RABBIT_PASSWORD}@${NODE_IP}:30672/dmapi"
DB_CONN="mysql+pymysql://dmapi:${DMAPI_DB_PASSWORD}@${NODE_IP}:30306/dmapi"

# Patch dataplane_inputs.yaml in-place for any empty connectivity values
python3 - <<PYEOF
import re

with open('${DATAPLANE_INPUTS}') as f:
    content = f.read()

def patch_if_empty(text, key, value):
    """Replace 'key: ""' or 'key: ' with detected value, only when field is currently empty."""
    if not value:
        return text
    pattern = r'(^' + re.escape(key) + r':\s*)("")?\s*$'
    replacement = r'\g<1>"' + value.replace('"', '\\"') + '"'
    return re.sub(pattern, replacement, text, flags=re.MULTILINE)

content = patch_if_empty(content, 'dmapi_transport_url',       '${TRANSPORT_URL}')
content = patch_if_empty(content, 'dmapi_database_connection', '${DB_CONN}')
content = patch_if_empty(content, 'keystone_auth_url',         '${KEYSTONE_URL}')

with open('${DATAPLANE_INPUTS}', 'w') as f:
    f.write(content)
print("Connectivity values written to dataplane_inputs.yaml.")
PYEOF

# ---------- Step 2: Generate Ansible inventory ----------

step "Step 2: Generating Ansible inventory from OpenStack hypervisors..."

INVENTORY="${DATAPLANE_SCRIPTS}/inventory.ini"

if command -v openstack &>/dev/null; then
    openstack hypervisor list -f value -c 'Hypervisor Hostname' | \
        awk 'BEGIN{print "[trilio_data_plane]"} {print $1}' > "$INVENTORY"
    NODE_COUNT=$(grep -v '^\[' "$INVENTORY" | grep -c '\S' || true)
    info "Inventory written: ${NODE_COUNT} node(s) → $INVENTORY"
else
    warn "'openstack' CLI not found. Generating inventory from Kubernetes nodes..."
    kubectl get nodes -l openstack-hypervisor=enabled \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | awk 'BEGIN{print "[trilio_data_plane]"} NF{print}' > "$INVENTORY"
    NODE_COUNT=$(grep -v '^\[' "$INVENTORY" | grep -c '\S' || true)
    info "Inventory written: ${NODE_COUNT} node(s) (from Kubernetes labels) → $INVENTORY"
fi

[ -s "$INVENTORY" ] || err "Inventory is empty. No data plane nodes found."

# ---------- Step 3: Run Ansible playbook ----------

step "Step 3: Running Ansible playbook..."

LIMIT_ARG=""
[ -n "$ANSIBLE_LIMIT" ] && LIMIT_ARG="--limit ${ANSIBLE_LIMIT}"

(
    cd "${DATAPLANE_SCRIPTS}"
    # extra-vars path is relative to dataplane-scripts/ working directory
    ansible-playbook -i inventory.ini install_datamover.yml \
        --extra-vars "@../dataplane_inputs.yaml" \
        ${LIMIT_ARG}
)

# ---------- Step 4: Verify ----------

step "Step 4: Verifying DataMover service on all data plane nodes..."

(
    cd "${DATAPLANE_SCRIPTS}"
    ansible -i inventory.ini trilio_data_plane \
        -m command -a "systemctl is-active tvault-contego" \
        --become ${LIMIT_ARG} 2>&1 || true
)

echo ""
echo "=================================================="
info "Data plane deployment complete."
echo "=================================================="
