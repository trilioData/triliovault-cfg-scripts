#!/bin/bash
# deploy_infra.sh
#
# Deploys T4O infrastructure (MySQL InnoDB Cluster + RabbitMQ Cluster)
# on Sunbeam (MicroK8s) using infra_inputs.yaml.
#
# Skips MySQL or RabbitMQ with a warning if they already exist.
# To reinstall from scratch: bash scripts/uninstall_infra.sh
#
# What this script does:
#   1. Installs MySQL Operator for Kubernetes (trilio-openstack namespace)
#   2. Installs RabbitMQ Cluster Operator (trilio-openstack namespace)
#   3. Reads passwords from ctlplane_inputs.yaml and syncs to trilio-infra-passwords secret
#   4. Deploys MySQL InnoDB Cluster (trilio-mysql)
#   5. Initializes MySQL: creates workloadmgr and dmapi databases and users
#   6. Deploys RabbitMQ cluster (trilio-rabbitmq)
#   7. Initializes RabbitMQ: creates workloadmgr and dmapi vhosts, users, permissions
#   8. Creates NodePort services for compute node access (MySQL :30306, RabbitMQ :30672)
#
# Prerequisites:
#   - bash prepare.sh completed (namespace created, nodes labeled)
#   - kubectl configured against the MicroK8s cluster
#
# Usage:
#   bash deploy_infra.sh [--inputs-file infra_inputs.yaml]
#
# Options:
#   --inputs-file   Path to infra_inputs.yaml (default: same dir as this script)
#   -h, --help      Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy_infra.log"
exec > >(tee "$LOG_FILE") 2>&1
INPUTS_FILE="${SCRIPT_DIR}/infra_inputs.yaml"
CTLPLANE_INPUTS="${SCRIPT_DIR}/ctlplane_inputs.yaml"
NAMESPACE="trilio-openstack"
PASSWORDS_SECRET="trilio-infra-passwords"
MYSQL_OPERATOR_NS="$NAMESPACE"
RABBITMQ_OPERATOR_NS="$NAMESPACE"
APPLY_CHANGES=false

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

# Poll CRD + pod status every 10 s until the resource reaches Ready condition.
wait_with_pod_status() {
    local resource="$1" namespace="$2" timeout_secs="$3"
    local deadline=$((SECONDS + timeout_secs))

    while [ "$SECONDS" -lt "$deadline" ]; do
        echo ""
        echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} ${resource}:"
        kubectl get "$resource" -n "$namespace" 2>/dev/null || true
        echo ""
        echo "  Pods in ${namespace}:"
        kubectl get pods -n "$namespace" 2>/dev/null || true

        if kubectl wait "$resource" -n "$namespace" \
                --for=condition=Ready --timeout=1s &>/dev/null 2>&1; then
            return 0
        fi

        sleep 10
    done

    err "Timed out waiting for ${resource} to be Ready after $((timeout_secs / 60)) minutes"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)   INPUTS_FILE="$2"; shift 2 ;;
        --apply-changes) APPLY_CHANGES=true; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[ -f "$INPUTS_FILE" ] || err "infra_inputs.yaml not found: $INPUTS_FILE"

# ---------- Helper: read a dotted key from infra_inputs.yaml ----------

get_input() {
    local key="$1" default="$2"
    python3 - <<PYEOF 2>/dev/null || echo "$default"
import yaml
try:
    d = yaml.safe_load(open('${INPUTS_FILE}'))
    keys = '${key}'.split('.')
    val = d
    for k in keys: val = val[k]
    print(val if val is not None and val != '' else '${default}')
except Exception:
    print('${default}')
PYEOF
}

MYSQL_INSTANCES=$(get_input "mysql.instances" "3")
MYSQL_IMAGE=$(get_input "mysql.image" "")
MYSQL_ROUTER_IMAGE=$(get_input "mysql.router_image" "")
MYSQL_ROUTER_INSTANCES=$(get_input "mysql.router_instances" "1")
MYSQL_STORAGE_CLASS=$(get_input "mysql.storage.storage_class" "")
MYSQL_STORAGE_SIZE=$(get_input "mysql.storage.storage_size" "10Gi")
MYSQL_CPU_REQ=$(get_input "mysql.resources.requests.cpu" "250m")
MYSQL_MEM_REQ=$(get_input "mysql.resources.requests.memory" "512Mi")
MYSQL_CPU_LIM=$(get_input "mysql.resources.limits.cpu" "1000m")
MYSQL_MEM_LIM=$(get_input "mysql.resources.limits.memory" "2Gi")

RABBIT_REPLICAS=$(get_input "rabbitmq.replicas" "3")
RABBIT_IMAGE=$(get_input "rabbitmq.image" "")
RABBIT_STORAGE_CLASS=$(get_input "rabbitmq.storage.storage_class" "")
RABBIT_STORAGE_SIZE=$(get_input "rabbitmq.storage.storage_size" "8Gi")
RABBIT_CPU_REQ=$(get_input "rabbitmq.resources.requests.cpu" "100m")
RABBIT_MEM_REQ=$(get_input "rabbitmq.resources.requests.memory" "256Mi")
RABBIT_CPU_LIM=$(get_input "rabbitmq.resources.limits.cpu" "500m")
RABBIT_MEM_LIM=$(get_input "rabbitmq.resources.limits.memory" "1Gi")
RABBIT_QUORUM=$(get_input "rabbitmq.quorum_queues.enabled" "false")
RABBIT_EXTRA_CONFIG=$(python3 - <<PYEOF 2>/dev/null || echo ""
import yaml
d = yaml.safe_load(open('${INPUTS_FILE}'))
val = d.get('rabbitmq', {}).get('additional_config', '') or ''
print(val.strip())
PYEOF
)

echo "=================================================="
echo " T4O Sunbeam — Deploy Infrastructure"
echo " Namespace  : $NAMESPACE"
echo " Inputs     : $INPUTS_FILE"
echo " MySQL      : ${MYSQL_INSTANCES} instances, ${MYSQL_STORAGE_SIZE} storage"
echo " RabbitMQ   : ${RABBIT_REPLICAS} replicas, ${RABBIT_STORAGE_SIZE} storage"
echo " Log        : $LOG_FILE"
echo "=================================================="

# ---------- Skip if already deployed ----------

MYSQL_EXISTS=false
RABBIT_EXISTS=false
MYSQL_OPERATOR_EXISTS=false
RABBIT_OPERATOR_EXISTS=false

step "Checking existing infrastructure..."

if kubectl get deployment mysql-operator -n "$NAMESPACE" &>/dev/null; then
    if [ "$APPLY_CHANGES" = true ]; then
        info "MySQL Operator already deployed — re-applying updated manifest (--apply-changes)."
    else
        info "MySQL Operator already deployed in $NAMESPACE — skipping Step 1."
        MYSQL_OPERATOR_EXISTS=true
    fi
fi

if kubectl get deployment rabbitmq-cluster-operator -n "$NAMESPACE" &>/dev/null; then
    if [ "$APPLY_CHANGES" = true ]; then
        info "RabbitMQ Cluster Operator already deployed — re-applying updated manifest (--apply-changes)."
    else
        info "RabbitMQ Cluster Operator already deployed in $NAMESPACE — skipping Step 2."
        RABBIT_OPERATOR_EXISTS=true
    fi
fi

if kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" &>/dev/null; then
    MYSQL_STATUS=$(kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" \
        -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "Unknown")
    warn "MySQL InnoDB Cluster 'trilio-mysql' already exists (status: ${MYSQL_STATUS}) — skipping."
    warn "To reinstall: bash scripts/uninstall_infra.sh"
    MYSQL_EXISTS=true
fi

if kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" &>/dev/null; then
    if [ "$APPLY_CHANGES" = true ]; then
        info "RabbitMQ cluster already exists — re-applying manifest (--apply-changes)."
    else
        RABBIT_STATUS=$(kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        warn "RabbitMQ cluster 'trilio-rabbitmq' already exists (status: ${RABBIT_STATUS}) — skipping."
        warn "To reinstall: bash scripts/uninstall_infra.sh"
        RABBIT_EXISTS=true
    fi
fi

if [ "$MYSQL_EXISTS" = true ] && [ "$RABBIT_EXISTS" = true ]; then
    info "Both MySQL and RabbitMQ are already deployed — nothing to do."
    exit 0
fi

# ---------- Step 1: Install MySQL Operator ----------

if [ "$MYSQL_OPERATOR_EXISTS" = false ]; then
step "Step 1: Installing MySQL Operator for Kubernetes in namespace $NAMESPACE..."

MYSQL_OP_MANIFEST=$(mktemp)
curl -fsSL \
    https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-operator.yaml \
    -o "$MYSQL_OP_MANIFEST"

# Patch the manifest: move all resources into $NAMESPACE, skip Namespace object creation
# (trilio-openstack already exists), and inject MYSQL_OPERATOR_K8S_CLUSTER_DOMAIN=cluster.local
# into the Deployment — required on MicroK8s/Sunbeam because DNS-based cluster domain
# auto-detection fails with "Name or service not known".
python3 - <<PYEOF
import yaml

OLD_NS = 'mysql-operator'
NEW_NS = '${NAMESPACE}'

def replace_ns(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == 'namespace' and v == OLD_NS:
                obj[k] = NEW_NS
            else:
                replace_ns(v)
        # Also fix env vars like MYSQL_OPERATOR_ENABLED_NAMESPACES whose
        # value is the old namespace — the patching above only catches
        # keys literally named 'namespace', not env var value fields.
        if obj.get('name', '').endswith(('_NAMESPACE', '_NAMESPACES')) and \
                obj.get('value') == OLD_NS:
            obj['value'] = NEW_NS
    elif isinstance(obj, list):
        for item in obj:
            replace_ns(item)

with open('${MYSQL_OP_MANIFEST}') as f:
    docs = list(yaml.safe_load_all(f))

patched = []
for doc in docs:
    if doc is None:
        continue
    if doc.get('kind') == 'Namespace':
        continue
    replace_ns(doc)
    if doc.get('kind') == 'Deployment' and \
       doc.get('metadata', {}).get('name') == 'mysql-operator':
        containers = doc['spec']['template']['spec']['containers']
        for c in containers:
            env = c.setdefault('env', [])
            if not any(e.get('name') == 'MYSQL_OPERATOR_K8S_CLUSTER_DOMAIN' for e in env):
                env.append({'name': 'MYSQL_OPERATOR_K8S_CLUSTER_DOMAIN',
                            'value': 'cluster.local'})
    patched.append(doc)

with open('${MYSQL_OP_MANIFEST}', 'w') as f:
    yaml.dump_all(patched, f, default_flow_style=False)
PYEOF

kubectl apply -f \
    https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-crds.yaml
kubectl apply -f "$MYSQL_OP_MANIFEST"
rm -f "$MYSQL_OP_MANIFEST"

info "Waiting for MySQL Operator to be ready..."
kubectl wait deployment/mysql-operator \
    -n "$MYSQL_OPERATOR_NS" \
    --for=condition=Available \
    --timeout=300s

info "MySQL Operator ready."
fi  # MYSQL_OPERATOR_EXISTS

# ---------- Step 2: Install RabbitMQ Cluster Operator ----------

if [ "$RABBIT_OPERATOR_EXISTS" = false ]; then
step "Step 2: Installing RabbitMQ Cluster Operator in namespace $NAMESPACE..."

RABBIT_OP_MANIFEST=$(mktemp)
curl -fsSL \
    "https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml" \
    -o "$RABBIT_OP_MANIFEST"

# Patch the manifest: move all resources into $NAMESPACE, skip Namespace object creation.
# Also skip cert-manager resources (Certificate, Issuer) and the webhook configurations
# that depend on them if cert-manager is not installed in the cluster.
python3 - <<PYEOF
import yaml

OLD_NS = 'rabbitmq-system'
NEW_NS = '${NAMESPACE}'

# Skip cert-manager resources and admission webhooks — cert-manager is not deployed
# alongside T4O on Sunbeam; the operator functions correctly without them.
SKIP_KINDS = {'Namespace', 'Certificate', 'Issuer', 'ClusterIssuer',
              'MutatingWebhookConfiguration', 'ValidatingWebhookConfiguration'}

def replace_ns(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == 'namespace' and v == OLD_NS:
                obj[k] = NEW_NS
            else:
                replace_ns(v)
    elif isinstance(obj, list):
        for item in obj:
            replace_ns(item)

with open('${RABBIT_OP_MANIFEST}') as f:
    docs = list(yaml.safe_load_all(f))

patched = []
for doc in docs:
    if doc is None:
        continue
    if doc.get('kind', '') in SKIP_KINDS:
        continue
    replace_ns(doc)
    patched.append(doc)

with open('${RABBIT_OP_MANIFEST}', 'w') as f:
    yaml.dump_all(patched, f, default_flow_style=False)
PYEOF

# The operator binary unconditionally starts a webhook server (controller-runtime
# hardcodes it) and reads TLS certs from /tmp/k8s-webhook-server/serving-certs/.
# cert-manager is not available on Sunbeam, so generate a self-signed cert instead.
# The MutatingWebhookConfiguration is skipped (in SKIP_KINDS) so the API server
# never calls the webhook — the cert just needs to exist for the process to start.
info "Generating self-signed TLS cert for RabbitMQ operator webhook server..."
openssl req -x509 -newkey rsa:2048 \
    -keyout /tmp/rabbit-webhook-tls.key \
    -out    /tmp/rabbit-webhook-tls.crt \
    -days 3650 -nodes \
    -subj "/CN=rabbitmq-cluster-operator-webhook" 2>/dev/null
kubectl create secret tls cluster-operator-webhook-server-cert \
    -n "$NAMESPACE" \
    --cert=/tmp/rabbit-webhook-tls.crt \
    --key=/tmp/rabbit-webhook-tls.key \
    --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/rabbit-webhook-tls.key /tmp/rabbit-webhook-tls.crt

kubectl apply -f "$RABBIT_OP_MANIFEST"
rm -f "$RABBIT_OP_MANIFEST"

info "Waiting for RabbitMQ Cluster Operator to be ready..."
kubectl wait deployment/rabbitmq-cluster-operator \
    -n "$RABBITMQ_OPERATOR_NS" \
    --for=condition=Available \
    --timeout=300s

info "RabbitMQ Cluster Operator ready."
fi  # RABBIT_OPERATOR_EXISTS

# ---------- Step 3: Read passwords from ctlplane_inputs.yaml ----------

step "Step 3: Reading passwords from ctlplane_inputs.yaml..."

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

MYSQL_ROOT_PASSWORD=$(get_password "mysql_root")
MYSQL_WLM_PASSWORD=$(get_password "mysql_wlm")
MYSQL_DMAPI_PASSWORD=$(get_password "mysql_dmapi")
RABBITMQ_WLM_PASSWORD=$(get_password "rabbitmq_wlm")
RABBITMQ_DMAPI_PASSWORD=$(get_password "rabbitmq_dmapi")

[ -z "$MYSQL_ROOT_PASSWORD" ] && \
    err "Passwords not set in ctlplane_inputs.yaml. Run 'bash prepare.sh' first."

apply_secret() {
    local name="$1"; shift
    if [ "$APPLY_CHANGES" = true ]; then
        kubectl create secret generic "$name" "$@" --dry-run=client -o yaml | kubectl apply -f -
        info "Secret '$name' applied."
    elif ! kubectl get secret "$name" -n "$NAMESPACE" &>/dev/null; then
        kubectl create secret generic "$name" "$@"
        info "Secret '$name' created."
    else
        info "Secret '$name' already exists — skipping."
    fi
}

apply_secret "$PASSWORDS_SECRET" \
    -n "$NAMESPACE" \
    --from-literal=mysql-root-password="${MYSQL_ROOT_PASSWORD}" \
    --from-literal=mysql-wlm-password="${MYSQL_WLM_PASSWORD}" \
    --from-literal=mysql-dmapi-password="${MYSQL_DMAPI_PASSWORD}" \
    --from-literal=rabbitmq-wlm-password="${RABBITMQ_WLM_PASSWORD}" \
    --from-literal=rabbitmq-dmapi-password="${RABBITMQ_DMAPI_PASSWORD}"

# ---------- Step 4: Create MySQL credential secrets ----------

step "Step 4: Creating MySQL credential secrets..."

apply_secret trilio-mysql-root \
    -n "$NAMESPACE" \
    --from-literal=rootUser=root \
    --from-literal=rootPassword="${MYSQL_ROOT_PASSWORD}" \
    --from-literal=rootHost='%'

apply_secret trilio-mysql-wlm \
    -n "$NAMESPACE" \
    --from-literal=password="${MYSQL_WLM_PASSWORD}"

apply_secret trilio-mysql-dmapi \
    -n "$NAMESPACE" \
    --from-literal=password="${MYSQL_DMAPI_PASSWORD}"

# ---------- Step 5: Deploy MySQL InnoDB Cluster ----------

if [ "$MYSQL_EXISTS" = false ]; then
    step "Step 5: Deploying MySQL InnoDB Cluster (${MYSQL_INSTANCES} instances)..."

    kubectl apply -f - <<CREOF
apiVersion: mysql.oracle.com/v2
kind: InnoDBCluster
metadata:
  name: trilio-mysql
  namespace: ${NAMESPACE}
spec:
  secretName: trilio-mysql-root
  tlsUseSelfSigned: true
  instances: ${MYSQL_INSTANCES}
  router:
    instances: ${MYSQL_ROUTER_INSTANCES}
  datadirVolumeClaimTemplate:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${MYSQL_STORAGE_SIZE}
$([ -n "$MYSQL_STORAGE_CLASS" ] && echo "    storageClassName: ${MYSQL_STORAGE_CLASS}" || true)
  podSpec:
    nodeSelector:
      triliovault-control-plane: "enabled"
$([ -n "$MYSQL_IMAGE" ] && echo "    image: ${MYSQL_IMAGE}" || true)
    resources:
      requests:
        cpu: "${MYSQL_CPU_REQ}"
        memory: "${MYSQL_MEM_REQ}"
      limits:
        cpu: "${MYSQL_CPU_LIM}"
        memory: "${MYSQL_MEM_LIM}"
$([ -n "$MYSQL_ROUTER_IMAGE" ] && printf "  routerSpec:\n    podSpec:\n      image: %s" "${MYSQL_ROUTER_IMAGE}" || true)
CREOF

    info "Waiting for MySQL InnoDB Cluster to be ready (8-12 minutes, polling every 10s)..."
    wait_with_pod_status innodbcluster/trilio-mysql "$NAMESPACE" 1200
    info "MySQL InnoDB Cluster ready."

    # ---------- Step 6: Initialize MySQL ----------

    step "Step 6: Creating MySQL databases and users..."

    kubectl delete job trilio-mysql-init -n "$NAMESPACE" --ignore-not-found

    kubectl apply -f - <<JOBEOF
apiVersion: batch/v1
kind: Job
metadata:
  name: trilio-mysql-init
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      nodeSelector:
        triliovault-control-plane: "enabled"
      containers:
      - name: mysql-init
        image: mysql:8.0
        command: ["/bin/bash", "-c"]
        args:
        - |
          mysql \
            -h trilio-mysql.${NAMESPACE}.svc.cluster.local \
            -P 6446 -u root -p"${MYSQL_ROOT_PASSWORD}" \
            --ssl-mode=PREFERRED --connect-timeout=30 \
            -e "
          CREATE DATABASE IF NOT EXISTS workloadmgr CHARACTER SET utf8 COLLATE utf8_general_ci;
          CREATE DATABASE IF NOT EXISTS dmapi CHARACTER SET utf8 COLLATE utf8_general_ci;
          CREATE USER IF NOT EXISTS 'workloadmgr'@'%' IDENTIFIED BY '${MYSQL_WLM_PASSWORD}';
          CREATE USER IF NOT EXISTS 'dmapi'@'%' IDENTIFIED BY '${MYSQL_DMAPI_PASSWORD}';
          GRANT ALL PRIVILEGES ON workloadmgr.* TO 'workloadmgr'@'%';
          GRANT ALL PRIVILEGES ON dmapi.* TO 'dmapi'@'%';
          FLUSH PRIVILEGES;"
          echo "MySQL initialization complete."
JOBEOF

    kubectl wait job/trilio-mysql-init \
        -n "$NAMESPACE" --for=condition=Complete --timeout=10m
    info "MySQL databases and users created."
fi

# ---------- Step 7: Deploy RabbitMQ Cluster ----------

# Always clean up stale webhook configs before creating a RabbitmqCluster.
# These are left behind by partial or pre-fix deploys and block RabbitmqCluster
# creation with an "operation not permitted" webhook dial error.
kubectl delete mutatingwebhookconfiguration \
    cluster-operator-mutating-webhook-configuration --ignore-not-found 2>/dev/null || true
kubectl delete validatingwebhookconfiguration \
    cluster-operator-validating-webhook-configuration --ignore-not-found 2>/dev/null || true

if [ "$RABBIT_EXISTS" = false ]; then
    step "Step 7: Deploying RabbitMQ cluster (${RABBIT_REPLICAS} replicas)..."

    RABBIT_CONF_BLOCK=""
    RABBIT_QUORUM_CONF=""
    if [ "$RABBIT_QUORUM" = "true" ] || [ "$RABBIT_QUORUM" = "True" ]; then
        RABBIT_QUORUM_CONF=$'\n          default_queue_type = quorum\n          raft.wal_max_size_bytes = 134217728\n          raft.segment_max_entries = 32768'
    fi
    if [ -n "$RABBIT_QUORUM_CONF" ] || [ -n "$RABBIT_EXTRA_CONFIG" ]; then
        RABBIT_CONF_BLOCK="  rabbitmq:
    additionalConfig: |
$(echo "${RABBIT_QUORUM_CONF}${RABBIT_EXTRA_CONFIG}" | sed 's/^/      /')"
    fi

    kubectl apply -f - <<CREOF
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: trilio-rabbitmq
  namespace: ${NAMESPACE}
spec:
  replicas: ${RABBIT_REPLICAS}
$([ -n "$RABBIT_IMAGE" ] && printf "  image: %s" "${RABBIT_IMAGE}" || true)
  persistence:
    storage: ${RABBIT_STORAGE_SIZE}
$([ -n "$RABBIT_STORAGE_CLASS" ] && echo "    storageClassName: ${RABBIT_STORAGE_CLASS}" || true)
  resources:
    requests:
      cpu: "${RABBIT_CPU_REQ}"
      memory: "${RABBIT_MEM_REQ}"
    limits:
      cpu: "${RABBIT_CPU_LIM}"
      memory: "${RABBIT_MEM_LIM}"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: triliovault-control-plane
            operator: In
            values:
            - "enabled"
${RABBIT_CONF_BLOCK}
CREOF

    info "Waiting for RabbitMQ cluster to be ready (3-5 minutes, polling every 10s)..."
    wait_with_pod_status rabbitmqcluster/trilio-rabbitmq "$NAMESPACE" 600
    info "RabbitMQ cluster ready."

    # ---------- Step 8: Initialize RabbitMQ ----------

    step "Step 8: Creating RabbitMQ vhosts and users..."

    RABBITMQ_ADMIN_USER=$(kubectl get secret trilio-rabbitmq-default-user \
        -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
    RABBITMQ_ADMIN_PASS=$(kubectl get secret trilio-rabbitmq-default-user \
        -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

    kubectl delete job trilio-rabbitmq-init -n "$NAMESPACE" --ignore-not-found

    kubectl apply -f - <<JOBEOF
apiVersion: batch/v1
kind: Job
metadata:
  name: trilio-rabbitmq-init
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      nodeSelector:
        triliovault-control-plane: "enabled"
      containers:
      - name: rabbitmq-init
        image: curlimages/curl:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          MGMT="http://trilio-rabbitmq.${NAMESPACE}.svc.cluster.local:15672"
          AUTH="${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASS}"
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/vhosts/workloadmgr"
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/vhosts/dmapi"
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/users/workloadmgr" \
            -H "Content-Type: application/json" \
            -d '{"password":"${RABBITMQ_WLM_PASSWORD}","tags":""}'
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/users/dmapi" \
            -H "Content-Type: application/json" \
            -d '{"password":"${RABBITMQ_DMAPI_PASSWORD}","tags":""}'
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/permissions/workloadmgr/workloadmgr" \
            -H "Content-Type: application/json" \
            -d '{"configure":".*","write":".*","read":".*"}'
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/permissions/dmapi/dmapi" \
            -H "Content-Type: application/json" \
            -d '{"configure":".*","write":".*","read":".*"}'
          echo "RabbitMQ initialization complete."
JOBEOF

    kubectl wait job/trilio-rabbitmq-init \
        -n "$NAMESPACE" --for=condition=Complete --timeout=5m
    info "RabbitMQ vhosts and users created."
fi

# ---------- Step 9: Create NodePort services ----------

step "Step 9: Creating NodePort services for compute node access..."

if ! kubectl get service trilio-mysql-nodeport -n "$NAMESPACE" &>/dev/null; then
    kubectl expose service trilio-mysql \
        --name=trilio-mysql-nodeport --type=NodePort --port=6446 --target-port=6446 \
        -n "$NAMESPACE"
    kubectl patch service trilio-mysql-nodeport -n "$NAMESPACE" \
        --type='json' -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30306}]'
    info "MySQL NodePort created: 30306 -> 6446"
else
    info "MySQL NodePort service already exists."
fi

if ! kubectl get service trilio-rabbitmq-nodeport -n "$NAMESPACE" &>/dev/null; then
    kubectl expose service trilio-rabbitmq \
        --name=trilio-rabbitmq-nodeport --type=NodePort --port=5672 --target-port=5672 \
        -n "$NAMESPACE"
    kubectl patch service trilio-rabbitmq-nodeport -n "$NAMESPACE" \
        --type='json' -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30672}]'
    info "RabbitMQ NodePort created: 30672 -> 5672"
else
    info "RabbitMQ NodePort service already exists."
fi

echo ""
echo "=================================================="
info "Infrastructure deployment complete."
echo ""
echo "  MySQL    : trilio-mysql.${NAMESPACE}.svc.cluster.local:6446"
echo "  RabbitMQ : trilio-rabbitmq.${NAMESPACE}.svc.cluster.local:5672"
echo ""
echo "  NodePort (for compute nodes):"
echo "    MySQL    : <node-ip>:30306"
echo "    RabbitMQ : <node-ip>:30672"
echo ""
echo "  Next step:"
echo "    bash deploy_ctlplane.sh"
echo "=================================================="
