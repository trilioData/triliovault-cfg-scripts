#!/bin/bash
# deploy_ctlplane.sh
#
# Deploys T4O control plane on Sunbeam (MicroK8s) by reading ctlplane_inputs.yaml.
#
# Prerequisites:
#   - bash prepare.sh completed (tools, nodes labeled, images populated)
#   - bash deploy_infra.sh completed (MySQL + RabbitMQ running)
#   - ctlplane_inputs.yaml reviewed
#
# Steps performed:
#   1. Read passwords from ctlplane_inputs.yaml
#   2. Auto-detect Keystone credentials
#   3. Generate trilio-ctlplane-values.yaml
#   4. Install or upgrade the tvo Helm release
#
# Usage:
#   bash deploy_ctlplane.sh [--inputs-file ctlplane_inputs.yaml]
#
# Options:
#   --inputs-file   Path to ctlplane_inputs.yaml (default: same dir as this script)
#   -h, --help      Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy_ctlplane.log"
exec > >(tee "$LOG_FILE") 2>&1
CTLPLANE_INPUTS="${SCRIPT_DIR}/ctlplane_inputs.yaml"
CTLPLANE_SCRIPTS="${SCRIPT_DIR}/ctlplane-scripts"
NAMESPACE="trilio-openstack"
INFRA_SECRET="trilio-infra-passwords"
VALUES_FILE="${CTLPLANE_SCRIPTS}/trilio-ctlplane-values.yaml"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }
need()  { echo -e "${RED}[NEED]${NC}  $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)  CTLPLANE_INPUTS="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[ -f "$CTLPLANE_INPUTS" ] || err "ctlplane_inputs.yaml not found: $CTLPLANE_INPUTS"

# ---------- Read ctlplane_inputs.yaml ----------

get_input() {
    local key="$1" default="$2"
    python3 - <<PYEOF 2>/dev/null || echo "$default"
import yaml
try:
    d = yaml.safe_load(open('${CTLPLANE_INPUTS}'))
    keys = '${key}'.split('.')
    val = d
    for k in keys: val = val[k]
    print(val if val is not None and val != '' else '${default}')
except Exception:
    print('${default}')
PYEOF
}

NAMESPACE=$(get_input "namespace" "trilio-openstack")
WLM_IMAGE=$(get_input "images.triliovault_wlm" "docker.io/trilio/trilio-wlm-canonical:6.2.1-2024.1")
DMAPI_IMAGE=$(get_input "images.triliovault_datamover_api" "docker.io/trilio/trilio-datamover-api-canonical:6.2.1-2024.1")
DMS_IMAGE=$(get_input "images.triliovault_dms" "docker.io/trilio/trilio-dms-canonical:6.2.1-2024.1")
PULL_POLICY=$(get_input "images.pull_policy" "IfNotPresent")
REGISTRY_LOGIN=$(get_input "registry.login_enabled" "false")
REGISTRY_URL=$(get_input "registry.url" "docker.io")
REGISTRY_USER=$(get_input "registry.username" "")
REGISTRY_PASS=$(get_input "registry.password" "")

echo "=================================================="
echo " T4O Sunbeam — Deploy Control Plane"
echo " Inputs    : $CTLPLANE_INPUTS"
echo " Namespace : $NAMESPACE"
echo " WLM image : $WLM_IMAGE"
echo " Log       : $LOG_FILE"
echo "=================================================="

# ---------- Verify infra is deployed ----------

kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" &>/dev/null || \
    err "MySQL InnoDB Cluster not found. Run 'bash deploy_infra.sh' first."
kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" &>/dev/null || \
    err "RabbitMQ cluster not found. Run 'bash deploy_infra.sh' first."
kubectl get secret "$INFRA_SECRET" -n "$NAMESPACE" &>/dev/null || \
    err "Secret '$INFRA_SECRET' not found. Run 'bash deploy_infra.sh' first."

# ---------- Step 1: Read passwords from ctlplane_inputs.yaml ----------

step "Step 1: Reading passwords from ctlplane_inputs.yaml..."

get_password() {
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

DB_HOST="trilio-mysql.${NAMESPACE}.svc.cluster.local"
DB_ROOT_PASSWORD=$(get_password "mysql_root")
MYSQL_WLM_PASSWORD=$(get_password "mysql_wlm")
MYSQL_DMAPI_PASSWORD=$(get_password "mysql_dmapi")
RABBITMQ_HOST="trilio-rabbitmq.${NAMESPACE}.svc.cluster.local"
RABBITMQ_WLM_PASSWORD=$(get_password "rabbitmq_wlm")
RABBITMQ_DMAPI_PASSWORD=$(get_password "rabbitmq_dmapi")
WLM_KEYSTONE_PASSWORD=$(get_password "keystone_wlm")
DMAPI_KEYSTONE_PASSWORD=$(get_password "keystone_dmapi")

[ -z "$DB_ROOT_PASSWORD" ] && \
    err "Passwords not set in ctlplane_inputs.yaml. Run 'bash prepare.sh' first."

info "DB host      : $DB_HOST"
info "RabbitMQ host: $RABBITMQ_HOST"

# ---------- Step 2: Auto-detect Keystone credentials ----------

step "Step 2: Auto-detecting Keystone credentials..."

if command -v sunbeam &>/dev/null; then
    OPENRC_OUTPUT=$(sunbeam openrc 2>/dev/null || echo "")
    [ -n "$OPENRC_OUTPUT" ] && eval "$OPENRC_OUTPUT" 2>/dev/null || true
fi

if [ -z "${OS_AUTH_URL:-}" ]; then
    KS_IP=$(kubectl -n openstack get service keystone-internal \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    [ -n "$KS_IP" ] && OS_AUTH_URL="http://${KS_IP}:5000/v3"
fi
if [ -z "${OS_PASSWORD:-}" ]; then
    OS_PASSWORD=$(kubectl -n openstack get secret keystone-keystone-admin \
        -o jsonpath='{.data.OS_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
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

# ctlplane_inputs.yaml values (populated by prepare.sh) take precedence over auto-detected
KS_AUTH_URL=$(get_input "keystone.auth_url" "${OS_AUTH_URL:-}")
KS_ADMIN_USER=$(get_input "keystone.admin_user" "${OS_USERNAME:-admin}")
KS_ADMIN_PASS=$(get_input "keystone.admin_password" "${OS_PASSWORD:-}")
KS_ADMIN_PROJECT=$(get_input "keystone.admin_project" "${OS_PROJECT_NAME:-admin}")
KS_REGION=$(get_input "keystone.region_name" "${OS_REGION_NAME:-RegionOne}")

[ -n "$KS_AUTH_URL" ] && info "Keystone URL : $KS_AUTH_URL" || \
    warn "Keystone URL not detected — fill keystone.auth_url in ctlplane_inputs.yaml"

# Prompt for any remaining missing required values
prompt_value() {
    local var_name="$1" label="$2"
    local current_val; current_val="$(eval "echo \"\${${var_name}:-}\"")"
    if [ -z "$current_val" ]; then
        need "$label not detected — enter it now:"
        local input; read -r -p "  > " input
        eval "${var_name}=\"${input}\""
    fi
}

prompt_value KS_AUTH_URL   "Keystone auth URL"
prompt_value KS_ADMIN_PASS "OpenStack admin password"

# ---------- Step 2.5: CA bundle ----------

CA_CERT_FILE="${SCRIPT_DIR}/sunbeam-ca.crt"
CA_BUNDLE_CM=""
if [ -f "$CA_CERT_FILE" ]; then
    step "Step 2.5: Creating CA bundle ConfigMap from sunbeam-ca.crt..."
    kubectl create configmap trilio-ca-bundle \
        --from-file=ca.crt="${CA_CERT_FILE}" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    CA_BUNDLE_CM="trilio-ca-bundle"
    info "CA bundle ConfigMap 'trilio-ca-bundle' created."
else
    info "sunbeam-ca.crt not found — no CA bundle. Run 'bash prepare.sh' to extract it."
fi

# ---------- Step 3: Write trilio-ctlplane-values.yaml ----------

step "Step 3: Generating trilio-ctlplane-values.yaml..."

cat > "$VALUES_FILE" <<EOF
# TVO Helm Chart — Generated Values
# WARNING: This file contains passwords. Do NOT commit it to git.

images:
  triliovault_wlm:           "${WLM_IMAGE}"
  triliovault_datamover_api: "${DMAPI_IMAGE}"
  triliovault_dms:           "${DMS_IMAGE}"
  pull_policy:               "${PULL_POLICY}"
  trilio_container_registry_login_enabled: ${REGISTRY_LOGIN}
  registry_url:      "${REGISTRY_URL}"
  registry_username: "${REGISTRY_USER}"
  registry_password: "${REGISTRY_PASS}"

keystone:
  auth_url:       "${KS_AUTH_URL}"
  admin_user:     "${KS_ADMIN_USER}"
  admin_password: "${KS_ADMIN_PASS}"
  admin_project:  "${KS_ADMIN_PROJECT}"
  region_name:    "${KS_REGION}"
  wlm_api:
    password: "${WLM_KEYSTONE_PASSWORD}"
  datamover_api:
    password: "${DMAPI_KEYSTONE_PASSWORD}"

database:
  host:          "${DB_HOST}"
  port:          "6446"
  root_password: "${DB_ROOT_PASSWORD}"
  wlm_api:
    password: "${MYSQL_WLM_PASSWORD}"
  datamover_api:
    password: "${MYSQL_DMAPI_PASSWORD}"

rabbitmq:
  host: "${RABBITMQ_HOST}"
  port: "5672"
  wlm_api:
    user:     "workloadmgr"
    password: "${RABBITMQ_WLM_PASSWORD}"
    vhost:    "workloadmgr"
  datamover_api:
    user:     "dmapi"
    password: "${RABBITMQ_DMAPI_PASSWORD}"
    vhost:    "dmapi"

service:
  wlm_api:
    type:      NodePort
    port:      8781
    node_port: 30781
  datamover_api:
    type:      NodePort
    port:      8784
    node_port: 30784

tls:
  ca_bundle_configmap: "${CA_BUNDLE_CM}"
EOF

info "Values written to: ${VALUES_FILE}"

# ---------- Step 4: Helm install / upgrade ----------

step "Step 4: Deploying T4O control plane via Helm..."

helm upgrade --install tvo \
    "${CTLPLANE_SCRIPTS}/helm-charts/tvo-chart" \
    --namespace "${NAMESPACE}" \
    --values    "${VALUES_FILE}" \
    --wait --timeout 15m

info "Helm release 'tvo' deployed successfully."

# ---------- Step 5: Verify ----------

step "Step 5: Verifying T4O control plane pods..."

kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/managed-by=Helm

NOT_RUNNING=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/managed-by=Helm \
    --no-headers 2>/dev/null | grep -v " Running " | grep -v "Completed" || true)

if [ -n "$NOT_RUNNING" ]; then
    warn "Some pods are not yet Running:"
    echo "$NOT_RUNNING"
    warn "Check logs: kubectl logs -n ${NAMESPACE} <pod-name>"
else
    info "All T4O control plane pods are Running."
fi

echo ""
echo "=================================================="
info "Control plane deployment complete."
echo ""
echo "  Next step:"
echo "    bash deploy_dataplane.sh"
echo "=================================================="
