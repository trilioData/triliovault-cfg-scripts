#!/bin/bash
# prepare.sh
#
# Prepares the full Sunbeam environment for T4O deployment:
#   1. Verify prerequisites (kubectl, python3-yaml)
#   2. Propagate manual_inputs.yaml (image tag + registry) into ctlplane/dataplane yamls
#   3. Install Helm CLI
#   4. Install Ansible + community.docker collection
#   5. Create trilio-openstack namespace and label control plane nodes
#   6. Auto-detect Keystone URL and admin credentials; update ctlplane_inputs.yaml
#   7. Print next steps
#
# After this script completes:
#   1. Run: bash deploy_infra.sh     — deploy MySQL + RabbitMQ
#   2. Run: bash deploy_ctlplane.sh  — deploy T4O control plane
#   3. Run: bash deploy_dataplane.sh — deploy T4O data plane
#
# Usage:
#   bash prepare.sh [--node-count N] [--helm-version X.Y.Z]
#
# Options:
#   --node-count     Override node_count from ctlplane_inputs.yaml
#   --helm-version   Override helm_version from ctlplane_inputs.yaml
#   -h, --help       Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CTLPLANE_INPUTS="${SCRIPT_DIR}/ctlplane_inputs.yaml"
DATAPLANE_INPUTS="${SCRIPT_DIR}/dataplane_inputs.yaml"
MANUAL_INPUTS="${SCRIPT_DIR}/manual_inputs.yaml"
CTLPLANE_SCRIPTS="${SCRIPT_DIR}/ctlplane-scripts"
NODE_COUNT_OVERRIDE=""
HELM_VERSION_OVERRIDE=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-count)    NODE_COUNT_OVERRIDE="$2"; shift 2 ;;
        --helm-version)  HELM_VERSION_OVERRIDE="$2"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

# ---------- Helper: read a value from ctlplane_inputs.yaml ----------

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

echo "=================================================="
echo " T4O Sunbeam — Prepare Environment"
echo "=================================================="

# ---------- Step 1: Prerequisites ----------

step "Step 1: Checking prerequisites..."
command -v kubectl &>/dev/null || err "kubectl not found. Run: microk8s config > ~/.kube/config"
python3 -c "import yaml" 2>/dev/null || err "python3-yaml not found. Run: sudo apt install python3-yaml"
[ -f "$CTLPLANE_INPUTS" ]  || err "ctlplane_inputs.yaml not found: $CTLPLANE_INPUTS"
[ -f "$DATAPLANE_INPUTS" ] || err "dataplane_inputs.yaml not found: $DATAPLANE_INPUTS"
info "Prerequisites OK."

NAMESPACE=$(get_input "namespace" "trilio-openstack")
NODE_COUNT="${NODE_COUNT_OVERRIDE:-$(get_input "node_count" "3")}"
HELM_VERSION="${HELM_VERSION_OVERRIDE:-$(get_input "helm_version" "3.17.2")}"

info "Namespace  : $NAMESPACE"
info "Node count : $NODE_COUNT"
info "Helm ver   : $HELM_VERSION"

# ---------- Step 2: Propagate manual_inputs.yaml ----------

step "Step 2: Propagating manual_inputs.yaml into ctlplane/dataplane yamls..."

if [ -f "$MANUAL_INPUTS" ]; then
    python3 - <<PYEOF
import re, yaml

with open('${MANUAL_INPUTS}') as f:
    m = yaml.safe_load(f)

TAG       = str(m.get('trilio_image_tag', '') or '').strip()
reg       = m.get('trilio_registry_auth', {}) or {}
REG_LOGIN = bool(reg.get('login_enabled', False))
REG_URL   = str(reg.get('url', '') or '').strip()
REG_USER  = str(reg.get('username', '') or '').strip()
REG_PASS  = str(reg.get('password', '') or '').strip()

REGISTRY  = REG_URL if REG_URL else 'docker.io'


def set_str_if_empty(text, key, value, indent=''):
    """Replace '<indent><key>: ""' with the given value, only when currently empty."""
    if not value:
        return text
    pat = r'(' + re.escape(indent + key) + r':\s*)""'
    return re.sub(pat, r'\g<1>"' + value.replace('\\\\', '\\\\\\\\').replace('"', '\\\\"') + '"', text)


def set_bool(text, key, value, indent=''):
    """Always overwrite a boolean key with the given value."""
    pat = r'(' + re.escape(indent + key) + r':\s*)(true|false)'
    return re.sub(pat, r'\g<1>' + ('true' if value else 'false'), text, flags=re.IGNORECASE)


# ---- Patch ctlplane_inputs.yaml ----
with open('${CTLPLANE_INPUTS}') as f:
    ctl = f.read()

if TAG:
    ctl = set_str_if_empty(ctl, 'triliovault_wlm',           f'{REGISTRY}/trilio/trilio-wlm-canonical:{TAG}',           '  ')
    ctl = set_str_if_empty(ctl, 'triliovault_datamover_api', f'{REGISTRY}/trilio/trilio-datamover-api-canonical:{TAG}', '  ')
    ctl = set_str_if_empty(ctl, 'triliovault_dms',           f'{REGISTRY}/trilio/trilio-dms-canonical:{TAG}',           '  ')

ctl = set_bool(ctl,           'login_enabled', REG_LOGIN, '  ')
if REG_URL:  ctl = set_str_if_empty(ctl, 'url',      REG_URL,  '  ')
if REG_USER: ctl = set_str_if_empty(ctl, 'username', REG_USER, '  ')
if REG_PASS: ctl = set_str_if_empty(ctl, 'password', REG_PASS, '  ')

with open('${CTLPLANE_INPUTS}', 'w') as f:
    f.write(ctl)

# ---- Patch dataplane_inputs.yaml ----
with open('${DATAPLANE_INPUTS}') as f:
    dp = f.read()

if TAG:
    dp = set_str_if_empty(dp, 'trilio_version',              TAG.split('-')[0])
    dp = set_str_if_empty(dp, 'triliovault_datamover_image', f'{REGISTRY}/trilio/trilio-datamover-canonical:{TAG}')
    dp = set_str_if_empty(dp, 'triliovault_wlm_image',       f'{REGISTRY}/trilio/trilio-wlm-canonical:{TAG}')
    dp = set_str_if_empty(dp, 'triliovault_dms_image',       f'{REGISTRY}/trilio/trilio-dms-canonical:{TAG}')

dp = set_bool(dp,           'trilio_container_registry_login_enabled', REG_LOGIN)
if REG_URL:  dp = set_str_if_empty(dp, 'trilio_container_registry_url',      REG_URL)
if REG_USER: dp = set_str_if_empty(dp, 'trilio_container_registry_username', REG_USER)
if REG_PASS: dp = set_str_if_empty(dp, 'trilio_container_registry_password', REG_PASS)

with open('${DATAPLANE_INPUTS}', 'w') as f:
    f.write(dp)

print(f"Tag '{TAG}' and registry settings propagated to ctlplane and dataplane yamls.")
PYEOF
else
    warn "manual_inputs.yaml not found — skipping image tag propagation."
    warn "Fill image tags manually in ctlplane_inputs.yaml and dataplane_inputs.yaml."
fi

# ---------- Step 3: Install Helm CLI ----------

step "Step 3: Install Helm CLI..."

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

# ---------- Step 4: Install Ansible ----------

step "Step 4: Install Ansible and community.docker collection..."

if command -v ansible &>/dev/null; then
    info "Ansible already installed ($(ansible --version | head -1)) — skipping."
else
    info "Installing Ansible..."
    sudo apt update -qq
    sudo apt install -y software-properties-common
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt install -y ansible
    info "Ansible $(ansible --version | head -1) installed."
fi

if ansible-galaxy collection list community.docker &>/dev/null 2>&1; then
    info "community.docker collection already installed — skipping."
else
    info "Installing community.docker collection..."
    ansible-galaxy collection install community.docker
fi

# ---------- Step 5: Create namespace and label nodes ----------

step "Step 5: Create namespace '$NAMESPACE' and label control plane nodes..."

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
    info "${ALREADY_COUNT} already labeled. Labeling ${NEEDED} more from openstack-control-plane=enabled pool..."

    CANDIDATES=$(kubectl get nodes -l openstack-control-plane=enabled \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    [ -n "$CANDIDATES" ] || err "No nodes with openstack-control-plane=enabled. Is Sunbeam running?"

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

# ---------- Step 6: Auto-detect Keystone values ----------

step "Step 6: Auto-detecting Keystone credentials from Sunbeam..."

if command -v sunbeam &>/dev/null; then
    OPENRC=$(sunbeam openrc 2>/dev/null || echo "")
    [ -n "$OPENRC" ] && eval "$OPENRC" 2>/dev/null || true
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

[ -n "${OS_AUTH_URL:-}" ] && info "Keystone URL : $OS_AUTH_URL" || \
    warn "Keystone URL not detected — fill keystone.auth_url manually in ctlplane_inputs.yaml"
[ -n "${OS_PASSWORD:-}" ] && info "Admin creds  : (detected)" || \
    warn "Admin password not detected — fill keystone.admin_password manually"

python3 - <<PYEOF
import re

with open('${CTLPLANE_INPUTS}') as f:
    content = f.read()

def patch_if_empty(text, key, value):
    if not value:
        return text
    pattern = r'(  ' + re.escape(key) + r':\s*)""'
    replacement = r'\g<1>"' + value.replace('"', '\\"') + '"'
    return re.sub(pattern, replacement, text)

content = patch_if_empty(content, 'auth_url',       '${OS_AUTH_URL:-}')
content = patch_if_empty(content, 'admin_password', '${OS_PASSWORD:-}')
content = patch_if_empty(content, 'admin_user',     '${OS_USERNAME:-}')
content = patch_if_empty(content, 'admin_project',  '${OS_PROJECT_NAME:-}')
content = patch_if_empty(content, 'region_name',    '${OS_REGION_NAME:-}')

with open('${CTLPLANE_INPUTS}', 'w') as f:
    f.write(content)
print("ctlplane_inputs.yaml updated with auto-detected Keystone values.")
PYEOF

# ---------- Summary ----------

echo ""
echo "=================================================="
info "Preparation complete."
echo ""
echo "  Review before deploying (optional):"
echo "    vi ctlplane_inputs.yaml    # images, node count, registry auth"
echo "    vi dataplane_inputs.yaml   # Ceph/SSL flags"
echo "    vi infra_inputs.yaml       # MySQL/RabbitMQ sizing and storage class"
echo ""
echo "  Deploy in order:"
echo "    bash deploy_infra.sh       # MySQL + RabbitMQ infrastructure"
echo "    bash deploy_ctlplane.sh    # T4O control plane (Helm)"
echo "    bash deploy_dataplane.sh   # T4O data plane (Ansible)"
echo "=================================================="
