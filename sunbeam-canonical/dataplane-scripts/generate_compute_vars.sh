#!/bin/bash
# generate_compute_vars.sh
#
# Auto-populates group_vars/compute.yml for DataMover deployment on compute nodes.
#
# Reads from:
#   - trilio-infra-passwords secret (populated by ctlplane-scripts/utils/deploy_infra.sh)
#   - Sunbeam cluster Keystone secret / sunbeam openrc
#   - MicroK8s node list (first control-plane node IP used for NodePort services)
#
# What it fills in automatically:
#   dmapi_transport_url, dmapi_database_connection, keystone_auth_url
#
# What remains for the user to set manually:
#   trilio_version, container images, registry auth, SSL flags, Ceph settings
#
# Usage:
#   bash generate_compute_vars.sh [--node-ip <IP>] [--rabbitmq-port <PORT>] [--db-port <PORT>]
#
# Options:
#   --node-ip        MicroK8s node IP reachable from compute nodes (auto-detected if omitted)
#   --rabbitmq-port  NodePort for RabbitMQ (default: 30672)
#   --db-port        NodePort for MySQL    (default: 30306)
#   -h, --help       Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VARS_FILE="${SCRIPT_DIR}/group_vars/compute.yml"
NAMESPACE="trilio-openstack"
INFRA_SECRET="trilio-infra-passwords"

RABBITMQ_NODEPORT="30672"
DB_NODEPORT="30306"
NODE_IP=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-ip)        NODE_IP="$2";          shift 2 ;;
        --rabbitmq-port)  RABBITMQ_NODEPORT="$2"; shift 2 ;;
        --db-port)        DB_NODEPORT="$2";       shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

echo "=================================================="
echo " Generate Compute Vars — DataMover group_vars"
echo " Target: $VARS_FILE"
echo "=================================================="

[ -f "$VARS_FILE" ] || err "group_vars/compute.yml not found at $VARS_FILE"

# ---------- 1. Read infra passwords ----------

read_secret() {
    kubectl get secret "$INFRA_SECRET" -n "$NAMESPACE" \
        -o "jsonpath={.data.${1}}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

kubectl get secret "$INFRA_SECRET" -n "$NAMESPACE" &>/dev/null \
    || err "Secret '$INFRA_SECRET' not found in namespace '$NAMESPACE'. Run ctlplane-scripts/utils/deploy_infra.sh first."

info "Reading credentials from '$INFRA_SECRET' secret..."
DMAPI_DB_PASSWORD=$(read_secret "mysql-dmapi-password")
DMAPI_RABBIT_PASSWORD=$(read_secret "rabbitmq-dmapi-password")

[ -n "$DMAPI_DB_PASSWORD" ]     || err "mysql-dmapi-password is empty in '$INFRA_SECRET'"
[ -n "$DMAPI_RABBIT_PASSWORD" ] || err "rabbitmq-dmapi-password is empty in '$INFRA_SECRET'"

# ---------- 2. Auto-detect MicroK8s node IP ----------

if [ -z "$NODE_IP" ]; then
    NODE_IP=$(kubectl get nodes -l openstack-control-plane=enabled \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
        2>/dev/null || echo "")
fi

[ -n "$NODE_IP" ] || err "Could not detect MicroK8s node IP. Pass --node-ip <IP>."
info "Node IP: $NODE_IP"

# ---------- 3. Detect Keystone auth URL ----------

KEYSTONE_AUTH_URL=""

if command -v sunbeam &>/dev/null; then
    OPENRC_OUTPUT=$(sunbeam openrc 2>/dev/null || echo "")
    [ -n "$OPENRC_OUTPUT" ] && eval "$OPENRC_OUTPUT" 2>/dev/null || true
    [ -n "${OS_AUTH_URL:-}" ] && KEYSTONE_AUTH_URL="$OS_AUTH_URL"
fi

if [ -z "$KEYSTONE_AUTH_URL" ]; then
    KS_IP=$(kubectl -n openstack get service keystone-internal \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    [ -n "$KS_IP" ] && KEYSTONE_AUTH_URL="http://${KS_IP}:5000/v3"
fi

[ -n "$KEYSTONE_AUTH_URL" ] && info "Keystone URL: $KEYSTONE_AUTH_URL" \
    || warn "Could not detect Keystone URL — leaving placeholder in vars file."

# ---------- 4. Patch group_vars/compute.yml ----------

info "Patching $VARS_FILE ..."

TRANSPORT_URL="rabbit://dmapi:${DMAPI_RABBIT_PASSWORD}@${NODE_IP}:${RABBITMQ_NODEPORT}/dmapi"
DB_CONN="mysql+pymysql://dmapi:${DMAPI_DB_PASSWORD}@${NODE_IP}:${DB_NODEPORT}/dmapi"

# Use sed to replace the placeholder lines in-place.
# Passwords are hex strings (no special shell chars) — safe to embed directly.

sed -i \
    "s|dmapi_transport_url:.*|dmapi_transport_url:       \"${TRANSPORT_URL}\"|" \
    "$VARS_FILE"

sed -i \
    "s|dmapi_database_connection:.*|dmapi_database_connection: \"${DB_CONN}\"|" \
    "$VARS_FILE"

if [ -n "$KEYSTONE_AUTH_URL" ]; then
    sed -i \
        "s|keystone_auth_url:.*|keystone_auth_url:    \"${KEYSTONE_AUTH_URL}\"|" \
        "$VARS_FILE"
fi

echo ""
echo "=================================================="
info "group_vars/compute.yml updated."
echo ""
echo "  dmapi_transport_url       : $TRANSPORT_URL"
echo "  dmapi_database_connection : $DB_CONN"
[ -n "$KEYSTONE_AUTH_URL" ] && echo "  keystone_auth_url         : $KEYSTONE_AUTH_URL"
echo ""
warn "Review the following before running the playbook:"
echo "  - trilio_version and container image tags"
echo "  - trilio_container_registry_login_enabled (and credentials if true)"
echo "  - rabbit_ssl / oslomsg_rpc_use_ssl / rabbit_quorum_queue"
echo "  - cinder_backend_ceph (and Ceph settings if true)"
echo ""
echo "  Then run:"
echo "    ansible-playbook -i inventory.ini install_datamover.yml"
echo "=================================================="
