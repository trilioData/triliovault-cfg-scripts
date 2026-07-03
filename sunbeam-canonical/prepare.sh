#!/bin/bash
# prepare.sh
#
# Prepares the full Sunbeam environment for T4O deployment:
#   1. Verify prerequisites (kubectl, python3-yaml)
#   2. Install Helm CLI
#   3. Install Ansible + community.docker collection
#   4. Create trilio-openstack namespace and label control plane nodes
#   5. Auto-detect Keystone URL and admin credentials; update ctlplane_inputs.yaml
#   6. Deploy MySQL InnoDB Cluster and RabbitMQ (skipped with a warning if already present)
#   7. Print next steps
#
# After this script completes:
#   1. Review ctlplane_inputs.yaml  — confirm images, storage class, registry auth
#   2. Review dataplane_inputs.yaml — set images, registry auth, Ceph/SSL flags
#   3. Run: bash deploy_ctlplane.sh
#   4. Run: bash deploy_dataplane.sh
#
# Usage:
#   bash prepare.sh [--node-count N] [--helm-version X.Y.Z] [--skip-infra]
#
# Options:
#   --node-count     Override node_count from ctlplane_inputs.yaml
#   --helm-version   Override helm_version from ctlplane_inputs.yaml
#   --skip-infra     Skip MySQL + RabbitMQ deployment (useful for re-runs)
#   -h, --help       Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CTLPLANE_INPUTS="${SCRIPT_DIR}/ctlplane_inputs.yaml"
CTLPLANE_SCRIPTS="${SCRIPT_DIR}/ctlplane-scripts"
SKIP_INFRA=false
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
        --skip-infra)    SKIP_INFRA=true; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

# ---------- Step 0: Prerequisites ----------

step "Step 0: Checking prerequisites..."
command -v kubectl &>/dev/null || err "kubectl not found. Run: microk8s config > ~/.kube/config"
python3 -c "import yaml" 2>/dev/null || err "python3-yaml not found. Run: sudo apt install python3-yaml"
[ -f "$CTLPLANE_INPUTS" ]  || err "ctlplane_inputs.yaml not found: $CTLPLANE_INPUTS"
info "Prerequisites OK."

NAMESPACE=$(get_input "namespace" "trilio-openstack")
NODE_COUNT="${NODE_COUNT_OVERRIDE:-$(get_input "node_count" "3")}"
HELM_VERSION="${HELM_VERSION_OVERRIDE:-$(get_input "helm_version" "3.17.2")}"

info "Namespace  : $NAMESPACE"
info "Node count : $NODE_COUNT"
info "Helm ver   : $HELM_VERSION"

# ---------- Step 1: Install Helm CLI ----------

step "Step 1: Install Helm CLI..."

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

# ---------- Step 2: Install Ansible ----------

step "Step 2: Install Ansible and community.docker collection..."

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

# ---------- Step 3: Create namespace and label nodes ----------

step "Step 3: Create namespace '$NAMESPACE' and label control plane nodes..."

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

# ---------- Step 4: Auto-detect Keystone values ----------

step "Step 4: Auto-detecting Keystone credentials from Sunbeam..."

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

# ---------- Step 5: Deploy MySQL and RabbitMQ infrastructure ----------

step "Step 5: Deploy infrastructure (MySQL InnoDB Cluster + RabbitMQ)..."

if [ "$SKIP_INFRA" = true ]; then
    info "--skip-infra: skipping infrastructure deployment."
else
    MYSQL_EXISTS=false; RABBIT_EXISTS=false

    if kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" &>/dev/null; then
        MYSQL_STATUS=$(kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" \
            -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "Unknown")
        warn "MySQL InnoDB Cluster 'trilio-mysql' already exists (status: ${MYSQL_STATUS}) — skipping MySQL deployment."
        warn "To reinstall MySQL, run: bash uninstall_infra.sh"
        MYSQL_EXISTS=true
    fi

    if kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" &>/dev/null; then
        RABBIT_STATUS=$(kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        warn "RabbitMQ cluster 'trilio-rabbitmq' already exists (status: ${RABBIT_STATUS}) — skipping RabbitMQ deployment."
        warn "To reinstall RabbitMQ, run: bash uninstall_infra.sh"
        RABBIT_EXISTS=true
    fi

    if [ "$MYSQL_EXISTS" = false ] || [ "$RABBIT_EXISTS" = false ]; then
        # Write a temp infra_inputs.yaml from ctlplane_inputs.yaml mysql/rabbitmq sections
        TEMP_INFRA="$(mktemp /tmp/infra_inputs_XXXXXX.yaml)"
        python3 - <<PYEOF
import yaml
with open('${CTLPLANE_INPUTS}') as f:
    c = yaml.safe_load(f)
infra = {'mysql': c.get('mysql', {}), 'rabbitmq': c.get('rabbitmq', {})}
with open('${TEMP_INFRA}', 'w') as f:
    yaml.dump(infra, f, default_flow_style=False)
PYEOF
        bash "${CTLPLANE_SCRIPTS}/deploy_infra.sh" --inputs-file "${TEMP_INFRA}"
        rm -f "${TEMP_INFRA}"
    else
        info "Both MySQL and RabbitMQ are already deployed — no infra changes made."
    fi
fi

# ---------- Summary ----------

echo ""
echo "=================================================="
info "Preparation complete."
echo ""
echo "  Review and edit before deploying:"
echo "    vi ctlplane_inputs.yaml    # images, storage_class, registry auth"
echo "    vi dataplane_inputs.yaml   # images, registry auth, Ceph/SSL flags"
echo ""
echo "  To redeploy infra from scratch:"
echo "    bash uninstall_infra.sh"
echo ""
echo "  Deploy:"
echo "    bash deploy_ctlplane.sh    # T4O control plane (Helm)"
echo "    bash deploy_dataplane.sh   # T4O data plane (Ansible)"
echo "=================================================="
