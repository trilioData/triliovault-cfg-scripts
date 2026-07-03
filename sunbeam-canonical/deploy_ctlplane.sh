#!/bin/bash
# deploy_ctlplane.sh
#
# Deploys T4O control plane on Sunbeam (MicroK8s) by reading ctlplane_inputs.yaml.
#
# Prerequisites:
#   - bash prepare.sh completed (Helm, Ansible, nodes labeled, MySQL + RabbitMQ deployed)
#   - ctlplane_inputs.yaml reviewed and configured (images, registry auth)
#
# Steps performed:
#   1. Generate trilio-ctlplane-values.yaml from cluster secrets + ctlplane_inputs.yaml
#   2. Merge image tags and registry auth into the values file
#   3. Install or upgrade the tvo Helm release
#   4. Verify all T4O pods are Running
#
# Usage:
#   bash deploy_ctlplane.sh [--inputs-file ctlplane_inputs.yaml]
#
# Options:
#   --inputs-file   Path to ctlplane_inputs.yaml (default: same dir as this script)
#   -h, --help      Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CTLPLANE_INPUTS="${SCRIPT_DIR}/ctlplane_inputs.yaml"
CTLPLANE_SCRIPTS="${SCRIPT_DIR}/ctlplane-scripts"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)  CTLPLANE_INPUTS="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
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
WLM_IMAGE=$(get_input "images.triliovault_wlm" "docker.io/trilio/trilio-wlm:6.2.1-stable-caracal-ubuntu_jammy")
DMAPI_IMAGE=$(get_input "images.triliovault_datamover_api" "docker.io/trilio/trilio-datamover-api:6.2.1-stable-caracal-ubuntu_jammy")
DMS_IMAGE=$(get_input "images.triliovault_dms" "docker.io/trilio/trilio-dms:6.2.1-stable-caracal-ubuntu_jammy")
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
echo "=================================================="

# ---------- Verify infra is deployed ----------

kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" &>/dev/null || \
    err "MySQL InnoDB Cluster not found. Run 'bash prepare.sh' first."
kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" &>/dev/null || \
    err "RabbitMQ cluster not found. Run 'bash prepare.sh' first."
kubectl get secret trilio-infra-passwords -n "$NAMESPACE" &>/dev/null || \
    err "Secret 'trilio-infra-passwords' not found. Run 'bash prepare.sh' first."

# ---------- Step 1: Generate trilio-ctlplane-values.yaml ----------

step "Step 1: Generating trilio-ctlplane-values.yaml from cluster..."

bash "${CTLPLANE_SCRIPTS}/generate_overrides.sh" \
    --registry-login-enabled "${REGISTRY_LOGIN}" \
    --registry-url           "${REGISTRY_URL}" \
    --registry-username      "${REGISTRY_USER}" \
    --registry-password      "${REGISTRY_PASS}"

# ---------- Step 2: Merge image tags into generated values file ----------

step "Step 2: Merging image tags from ctlplane_inputs.yaml..."

VALUES_FILE="${CTLPLANE_SCRIPTS}/trilio-ctlplane-values.yaml"
[ -f "$VALUES_FILE" ] || err "Values file not found: $VALUES_FILE"

python3 - <<PYEOF
import yaml

with open('${VALUES_FILE}') as f:
    vals = yaml.safe_load(f)

vals.setdefault('images', {})
vals['images']['triliovault_wlm']           = '${WLM_IMAGE}'
vals['images']['triliovault_datamover_api'] = '${DMAPI_IMAGE}'
vals['images']['triliovault_dms']           = '${DMS_IMAGE}'
vals['images']['pull_policy']               = '${PULL_POLICY}'

with open('${VALUES_FILE}', 'w') as f:
    yaml.dump(vals, f, default_flow_style=False, allow_unicode=True)

print("Image tags merged into ${VALUES_FILE}.")
PYEOF

# ---------- Step 3: Helm install / upgrade ----------

step "Step 3: Deploying T4O control plane via Helm..."

helm upgrade --install tvo \
    "${CTLPLANE_SCRIPTS}/helm-charts/tvo-chart" \
    --namespace "${NAMESPACE}" \
    --values    "${VALUES_FILE}" \
    --wait --timeout 15m

info "Helm release 'tvo' deployed successfully."

# ---------- Step 4: Verify ----------

step "Step 4: Verifying T4O control plane pods..."

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
