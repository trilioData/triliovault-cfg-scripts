#!/bin/bash
# deploy_dataplane.sh
#
# Deploys T4O DataMover on all Sunbeam compute nodes by reading dataplane_inputs.yaml.
#
# Prerequisites:
#   - bash prepare.sh completed (Ansible installed, nodes labeled)
#   - bash deploy_ctlplane.sh completed (MySQL cluster running)
#   - dataplane_inputs.yaml reviewed and configured (images, registry auth, flags)
#   - SSH access from this node to all compute nodes
#
# Steps performed:
#   1. Read DMAPI passwords from ctlplane_inputs.yaml; auto-detect node IP and Keystone URL
#   2. Generate Ansible inventory (inventory.ini) from OpenStack hypervisors
#   3. Run ansible-playbook install_datamover.yml
#   4. Verify tvault-contego service is active on all nodes
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
LOG_FILE="${SCRIPT_DIR}/deploy_dataplane.log"
exec > >(tee "$LOG_FILE") 2>&1
DATAPLANE_INPUTS="${SCRIPT_DIR}/dataplane_inputs.yaml"
CTLPLANE_INPUTS="${SCRIPT_DIR}/ctlplane_inputs.yaml"
DATAPLANE_SCRIPTS="${SCRIPT_DIR}/dataplane-scripts"
INVENTORY="${SCRIPT_DIR}/inventory.ini"
RESOLVED_VARS="${SCRIPT_DIR}/.dataplane_resolved.yml"
ANSIBLE_LIMIT=""

NAMESPACE="trilio-openstack"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)  DATAPLANE_INPUTS="$2"; shift 2 ;;
        --limit)        ANSIBLE_LIMIT="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[ -f "$DATAPLANE_INPUTS" ] || err "dataplane_inputs.yaml not found: $DATAPLANE_INPUTS"

echo "=================================================="
echo " T4O Sunbeam — Deploy Data Plane"
echo " Inputs    : $DATAPLANE_INPUTS"
echo " Log       : $LOG_FILE"
echo "=================================================="

# ---------- Step 1: Auto-populate connectivity values ----------

step "Step 1: Auto-populating connectivity from ctlplane_inputs.yaml and cluster..."

kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" &>/dev/null || \
    err "MySQL cluster not found. Run 'bash deploy_infra.sh' first."

get_ctlplane_password() {
    local key="$1"
    python3 - <<PYEOF 2>/dev/null || echo ""
import yaml
try:
    d = yaml.safe_load(open('${CTLPLANE_INPUTS}'))
    val = (d.get('passwords') or {}).get('${key}') or ''
    print(val)
except Exception:
    print('')
PYEOF
}

DMAPI_RABBIT_PASSWORD=$(get_ctlplane_password "rabbitmq_dmapi")
DMAPI_DB_PASSWORD=$(get_ctlplane_password "mysql_dmapi")

[ -z "$DMAPI_RABBIT_PASSWORD" ] && \
    err "Passwords not set in ctlplane_inputs.yaml. Run 'bash prepare.sh' first."

NODE_IP=$(kubectl get nodes -l openstack-control-plane=enabled \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "")
[ -n "$NODE_IP" ] && info "Node IP: $NODE_IP" || \
    warn "Could not auto-detect node IP. Connectivity values may need manual editing."

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

TRANSPORT_URL="rabbit://dmapi:${DMAPI_RABBIT_PASSWORD}@${NODE_IP}:30672/dmapi"
DB_CONN="mysql+pymysql://dmapi:${DMAPI_DB_PASSWORD}@${NODE_IP}:30306/dmapi"

# Build a resolved vars file — dataplane_inputs.yaml + auto-detected fallbacks for empty fields.
# dataplane_inputs.yaml is never modified; it remains the source of truth.
python3 - <<PYEOF
import yaml

with open('${DATAPLANE_INPUTS}') as f:
    data = yaml.safe_load(f) or {}

def fill_if_empty(key, value):
    if value and not str(data.get(key, '') or '').strip():
        data[key] = value

fill_if_empty('dmapi_transport_url',       '${TRANSPORT_URL}')
fill_if_empty('dmapi_database_connection', '${DB_CONN}')
fill_if_empty('keystone_auth_url',         '${KEYSTONE_URL}')

with open('${RESOLVED_VARS}', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
print("Resolved vars written (dataplane_inputs.yaml unchanged).")
PYEOF

# ---------- Step 2: Generate Ansible inventory ----------

step "Step 2: Generating Ansible inventory from OpenStack hypervisors..."

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

ANSIBLE_CONFIG="${DATAPLANE_SCRIPTS}/ansible.cfg" \
ansible-playbook \
    -i "${INVENTORY}" \
    "${DATAPLANE_SCRIPTS}/install_datamover.yml" \
    --extra-vars "@${RESOLVED_VARS}" \
    ${LIMIT_ARG}

rm -f "${RESOLVED_VARS}"

# ---------- Step 4: Verify ----------

step "Step 4: Verifying DataMover service on all data plane nodes..."

ANSIBLE_CONFIG="${DATAPLANE_SCRIPTS}/ansible.cfg" \
ansible \
    -i "${INVENTORY}" trilio_data_plane \
    -m command -a "systemctl is-active tvault-contego" \
    --become ${LIMIT_ARG} 2>&1 || true

echo ""
echo "=================================================="
info "Data plane deployment complete."
echo "=================================================="
