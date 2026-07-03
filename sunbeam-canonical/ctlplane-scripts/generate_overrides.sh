#!/bin/bash
# generate_overrides.sh
#
# Auto-generates trilio-ctlplane-values.yaml for the tvo-chart Helm release.
#
# Priority order for each value:
#   1. CLI flag (--db-host etc.)
#   2. trilio-infra-passwords secret (populated by deploy_infra.sh)
#   3. Auto-detect from Sunbeam cluster (Keystone URL, admin creds, node IP)
#   4. Interactive prompt (fallback for anything still missing)
#
# If you ran deploy_infra.sh first, this script needs zero user input.
#
# Usage:
#   bash generate_overrides.sh
#   bash generate_overrides.sh --db-host <HOST> --db-root-password <PASS> --rabbitmq-host <HOST>
#
# Optional flags:
#   --db-host            MySQL/MariaDB host (skip auto-detect)
#   --db-root-password   MySQL root password
#   --rabbitmq-host      RabbitMQ host
#   --rabbitmq-port      RabbitMQ port (default: 5672)
#   --node-ip            MicroK8s node IP for NodePort (auto-detected if omitted)
#
# Output: trilio-ctlplane-values.yaml in the same directory as this script
#
# WARNING: trilio-ctlplane-values.yaml contains passwords. Do NOT commit it to git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CTLPLANE_DIR="${SCRIPT_DIR}"
OVERRIDES_FILE="${CTLPLANE_DIR}/trilio-ctlplane-values.yaml"
NAMESPACE="trilio-openstack"
INFRA_SECRET="trilio-infra-passwords"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
need()  { echo -e "${RED}[NEED]${NC}  $*"; }

# ---------- Parse CLI arguments ----------

DB_HOST=""; DB_ROOT_PASSWORD=""; RABBITMQ_HOST=""; RABBITMQ_PORT="5672"; NODE_IP=""
REGISTRY_LOGIN_ENABLED="false"; REGISTRY_URL="docker.io"; REGISTRY_USERNAME=""; REGISTRY_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db-host)                        DB_HOST="$2";               shift 2 ;;
        --db-root-password)               DB_ROOT_PASSWORD="$2";      shift 2 ;;
        --rabbitmq-host)                  RABBITMQ_HOST="$2";         shift 2 ;;
        --rabbitmq-port)                  RABBITMQ_PORT="$2";         shift 2 ;;
        --node-ip)                        NODE_IP="$2";                shift 2 ;;
        --registry-login-enabled)         REGISTRY_LOGIN_ENABLED="$2"; shift 2 ;;
        --registry-url)                   REGISTRY_URL="$2";          shift 2 ;;
        --registry-username)              REGISTRY_USERNAME="$2";     shift 2 ;;
        --registry-password)              REGISTRY_PASSWORD="$2";     shift 2 ;;
        -h|--help) sed -n '2,35p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "=================================================="
echo " TVO Chart — Generate Overrides"
echo "=================================================="

# ---------- 1. Read from trilio-infra-passwords secret (deploy_infra.sh output) ----------

read_infra_secret() {
    local key="$1"
    kubectl get secret "$INFRA_SECRET" -n "$NAMESPACE" \
        -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

INFRA_SECRET_EXISTS=false
if kubectl get secret "$INFRA_SECRET" -n "$NAMESPACE" &>/dev/null; then
    INFRA_SECRET_EXISTS=true
    info "Found '$INFRA_SECRET' secret — reading infra credentials..."

    [ -z "$DB_HOST" ]            && DB_HOST="trilio-mysql.${NAMESPACE}.svc.cluster.local"
    [ -z "$DB_ROOT_PASSWORD" ]   && DB_ROOT_PASSWORD=$(read_infra_secret "mysql-root-password")
    [ -z "$RABBITMQ_HOST" ]      && RABBITMQ_HOST="trilio-rabbitmq.${NAMESPACE}.svc.cluster.local"

    MYSQL_WLM_PASSWORD=$(read_infra_secret "mysql-wlm-password")
    MYSQL_DMAPI_PASSWORD=$(read_infra_secret "mysql-dmapi-password")
    RABBITMQ_WLM_PASSWORD=$(read_infra_secret "rabbitmq-wlm-password")
    RABBITMQ_DMAPI_PASSWORD=$(read_infra_secret "rabbitmq-dmapi-password")

    info "DB host      : $DB_HOST"
    info "RabbitMQ host: $RABBITMQ_HOST"
else
    warn "Secret '$INFRA_SECRET' not found in namespace '$NAMESPACE'."
    warn "If you deployed external DB/RabbitMQ, provide values via CLI flags or interactive prompt."
    warn "To deploy T4O-managed infra first, run: bash utils/deploy_infra.sh"
    MYSQL_WLM_PASSWORD=""; MYSQL_DMAPI_PASSWORD=""
    RABBITMQ_WLM_PASSWORD=""; RABBITMQ_DMAPI_PASSWORD=""
fi

# ---------- 2. Auto-detect Keystone credentials from Sunbeam ----------

info "Reading OpenStack admin credentials from Sunbeam cluster..."

if command -v sunbeam &>/dev/null; then
    OPENRC_OUTPUT=$(sunbeam openrc 2>/dev/null || echo "")
    [ -n "$OPENRC_OUTPUT" ] && eval "$OPENRC_OUTPUT" 2>/dev/null || true
    [ -n "${OS_PASSWORD:-}" ] && info "Admin credentials loaded from 'sunbeam openrc'"
fi

if [ -z "${OS_PASSWORD:-}" ]; then
    OS_PASSWORD=$(kubectl -n openstack get secret keystone-keystone-admin \
        -o jsonpath='{.data.OS_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi
if [ -z "${OS_AUTH_URL:-}" ]; then
    KS_IP=$(kubectl -n openstack get service keystone-internal \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    [ -n "$KS_IP" ] && OS_AUTH_URL="http://${KS_IP}:5000/v3"
fi
if [ -z "${OS_USERNAME:-}" ]; then
    OS_USERNAME=$(kubectl -n openstack get secret keystone-keystone-admin \
        -o jsonpath='{.data.OS_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")
fi
if [ -z "${OS_PROJECT_NAME:-}" ]; then
    OS_PROJECT_NAME=$(kubectl -n openstack get secret keystone-keystone-admin \
        -o jsonpath='{.data.OS_PROJECT_NAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")
fi
if [ -z "${OS_REGION_NAME:-}" ]; then
    OS_REGION_NAME=$(kubectl -n openstack get secret keystone-keystone-admin \
        -o jsonpath='{.data.OS_REGION_NAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "RegionOne")
fi

[ -n "${OS_AUTH_URL:-}" ]    && info "Keystone URL   : $OS_AUTH_URL"
[ -n "${OS_PASSWORD:-}" ]    && info "Admin password : (found)"
[ -n "${OS_USERNAME:-}" ]    && info "Admin user     : $OS_USERNAME"
[ -n "${OS_REGION_NAME:-}" ] && info "Region         : $OS_REGION_NAME"

# ---------- 3. Auto-detect MicroK8s node IP ----------

if [ -z "$NODE_IP" ]; then
    NODE_IP=$(kubectl get nodes -l openstack-control-plane=enabled \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
        2>/dev/null || echo "")
    [ -n "$NODE_IP" ] && info "Node IP        : $NODE_IP"
fi

# ---------- 4. Prompt for any still-missing values ----------

prompt_value() {
    local var_name="$1" label="$2" current_val
    current_val="$(eval "echo \"\${${var_name}:-}\"")"
    if [ -z "$current_val" ]; then
        need "$label not detected — enter it now:"
        local input; read -r -p "  > " input
        eval "${var_name}=\"${input}\""
    fi
}

echo ""
info "Checking for values that require user input..."

prompt_value OS_AUTH_URL       "Keystone auth URL"
prompt_value OS_PASSWORD       "OpenStack admin password"
prompt_value NODE_IP           "MicroK8s node IP (reachable from compute nodes)"
prompt_value DB_HOST           "MySQL/MariaDB host"
prompt_value DB_ROOT_PASSWORD  "MySQL root password"
prompt_value RABBITMQ_HOST     "RabbitMQ host"

# ---------- 5. Generate T4O service passwords (if not already read from secret) ----------

gen_password() { openssl rand -hex 20; }

[ -z "$MYSQL_WLM_PASSWORD" ]   && MYSQL_WLM_PASSWORD=$(gen_password)   && info "Generated WLM DB password"
[ -z "$MYSQL_DMAPI_PASSWORD" ] && MYSQL_DMAPI_PASSWORD=$(gen_password) && info "Generated DMAPI DB password"
[ -z "$RABBITMQ_WLM_PASSWORD" ]  && RABBITMQ_WLM_PASSWORD=$(gen_password)  && info "Generated WLM RabbitMQ password"
[ -z "$RABBITMQ_DMAPI_PASSWORD" ] && RABBITMQ_DMAPI_PASSWORD=$(gen_password) && info "Generated DMAPI RabbitMQ password"

WLM_KEYSTONE_PASSWORD=$(gen_password)
DMAPI_KEYSTONE_PASSWORD=$(gen_password)

# ---------- 6. Write trilio-ctlplane-values.yaml ----------

info "Writing ${OVERRIDES_FILE} ..."

cat > "$OVERRIDES_FILE" <<EOF
# TVO Helm Chart — Generated Overrides
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
#
# WARNING: This file contains passwords. Do NOT commit it to git.
# Re-run generate_overrides.sh to regenerate.

images:
  trilio_container_registry_login_enabled: ${REGISTRY_LOGIN_ENABLED}
  registry_url: "${REGISTRY_URL}"
  registry_username: "${REGISTRY_USERNAME}"
  registry_password: "${REGISTRY_PASSWORD}"

keystone:
  auth_url: "${OS_AUTH_URL}"
  admin_user: "${OS_USERNAME:-admin}"
  admin_password: "${OS_PASSWORD}"
  admin_project: "${OS_PROJECT_NAME:-admin}"
  region_name: "${OS_REGION_NAME:-RegionOne}"
  wlm_api:
    password: "${WLM_KEYSTONE_PASSWORD}"
  datamover_api:
    password: "${DMAPI_KEYSTONE_PASSWORD}"

database:
  host: "${DB_HOST}"
  port: "6446"
  root_password: "${DB_ROOT_PASSWORD}"
  wlm_api:
    password: "${MYSQL_WLM_PASSWORD}"
  datamover_api:
    password: "${MYSQL_DMAPI_PASSWORD}"

rabbitmq:
  host: "${RABBITMQ_HOST}"
  port: "${RABBITMQ_PORT}"
  wlm_api:
    user: "workloadmgr"
    password: "${RABBITMQ_WLM_PASSWORD}"
    vhost: "workloadmgr"
  datamover_api:
    user: "dmapi"
    password: "${RABBITMQ_DMAPI_PASSWORD}"
    vhost: "dmapi"

service:
  wlm_api:
    type: NodePort
    port: 8781
    node_port: 30781
  datamover_api:
    type: NodePort
    port: 8784
    node_port: 30784
EOF

echo ""
echo "=================================================="
info "trilio-ctlplane-values.yaml written to:"
echo "    ${OVERRIDES_FILE}"
echo ""
if [ "$INFRA_SECRET_EXISTS" = true ]; then
    info "All infra credentials were read from the '$INFRA_SECRET' secret."
fi
echo ""
echo "  Next step — install:"
echo ""
echo "    helm upgrade --install tvo \\"
echo "      helm-charts/tvo-chart \\"
echo "      --namespace trilio-openstack \\"
echo "      --values trilio-ctlplane-values.yaml \\"
echo "      --wait --timeout 15m"
echo "=================================================="
