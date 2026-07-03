#!/bin/bash
# deploy_infra.sh
#
# Deploys TrilioVault infrastructure (MySQL InnoDB Cluster + RabbitMQ cluster)
# in the trilio-openstack namespace using official Kubernetes operators.
#
# Operators used:
#   - MySQL Operator for Kubernetes (mysql/mysql-operator, GPL 2.0)
#     Deploys a 3-instance MySQL InnoDB Cluster with automatic failover.
#   - RabbitMQ Cluster Operator (rabbitmq/cluster-operator, MPL 2.0)
#     Deploys a 3-replica RabbitMQ cluster.
#
# What this script does:
#   1. Installs the MySQL Operator into the mysql-operator namespace
#   2. Installs the RabbitMQ Cluster Operator into the rabbitmq-system namespace
#   3. Generates random passwords and stores them in 'trilio-infra-passwords' secret
#   4. Deploys MySQL InnoDB Cluster (trilio-mysql)
#   5. Initializes MySQL: creates workloadmgr and dmapi databases and users
#   6. Deploys RabbitMQ cluster (trilio-rabbitmq)
#   7. Initializes RabbitMQ: creates workloadmgr and dmapi vhosts, users, permissions
#   8. Creates NodePort services for compute node access (MySQL :30306, RabbitMQ :30672)
#
# After this script completes, run:
#   bash generate_overrides.sh
#
# Prerequisites:
#   - kubectl configured against the MicroK8s cluster
#   - Internet access to pull operator manifests and container images
#   - Nodes labeled: kubectl label node <NODE> triliovault-control-plane=enabled
#   - python3 with PyYAML (sudo apt install python3-yaml)
#
# Usage:
#   bash deploy_infra.sh [--inputs-file infra_inputs.yaml] [--force-regenerate]
#
# Options:
#   --inputs-file        Path to infra_inputs.yaml (default: infra_inputs.yaml in script dir)
#   --force-regenerate   Regenerate all passwords even if they already exist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CTLPLANE_DIR="${SCRIPT_DIR}"
NAMESPACE="trilio-openstack"
FORCE_REGENERATE=false
PASSWORDS_SECRET="trilio-infra-passwords"
INPUTS_FILE="${SCRIPT_DIR}/infra_inputs.yaml"

MYSQL_OPERATOR_NS="mysql-operator"
RABBITMQ_OPERATOR_NS="rabbitmq-system"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)      INPUTS_FILE="$2"; shift 2 ;;
        --force-regenerate) FORCE_REGENERATE=true; shift ;;
        -h|--help) sed -n '2,43p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

# ---------- Read infra_inputs.yaml ----------

[ -f "$INPUTS_FILE" ] || err "inputs file not found: $INPUTS_FILE"

# Helper: read a dotted key from infra_inputs.yaml, return default if missing/null
get_input() {
    local key="$1" default="$2"
    python3 - <<PYEOF 2>/dev/null || echo "$default"
import yaml, sys
try:
    d = yaml.safe_load(open('${INPUTS_FILE}'))
    keys = '${key}'.split('.')
    val = d
    for k in keys:
        val = val[k]
    if val is None or val == '':
        print('${default}')
    else:
        print(val)
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
echo " TrilioVault Infrastructure Deployment"
echo " Namespace  : $NAMESPACE"
echo " Inputs     : $INPUTS_FILE"
echo " MySQL      : ${MYSQL_INSTANCES} instances, ${MYSQL_STORAGE_SIZE} storage"
echo " RabbitMQ   : ${RABBIT_REPLICAS} replicas, ${RABBIT_STORAGE_SIZE} storage"
echo "=================================================="

# ---------- Step 1: Install MySQL Operator for Kubernetes ----------

step "Installing MySQL Operator for Kubernetes..."

kubectl apply -f \
    https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-crds.yaml
kubectl apply -f \
    https://raw.githubusercontent.com/mysql/mysql-operator/trunk/deploy/deploy-operator.yaml

info "Waiting for MySQL Operator to be ready..."
kubectl wait deployment/mysql-operator \
    -n "$MYSQL_OPERATOR_NS" \
    --for=condition=Available \
    --timeout=300s

info "MySQL Operator ready."

# ---------- Step 2: Install RabbitMQ Cluster Operator ----------

step "Installing RabbitMQ Cluster Operator..."

kubectl apply -f \
    "https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml"

info "Waiting for RabbitMQ Cluster Operator to be ready..."
kubectl wait deployment/rabbitmq-cluster-operator \
    -n "$RABBITMQ_OPERATOR_NS" \
    --for=condition=Available \
    --timeout=300s

info "RabbitMQ Cluster Operator ready."

# ---------- Step 3: Ensure namespace exists ----------

kubectl get namespace "$NAMESPACE" &>/dev/null || \
    kubectl create namespace "$NAMESPACE"

# ---------- Step 4: Generate or reuse passwords ----------

if kubectl get secret "$PASSWORDS_SECRET" -n "$NAMESPACE" &>/dev/null \
        && [ "$FORCE_REGENERATE" = false ]; then
    info "Found existing '$PASSWORDS_SECRET' — reusing stored passwords."
    info "Run with --force-regenerate to create new passwords."

    MYSQL_ROOT_PASSWORD=$(kubectl get secret "$PASSWORDS_SECRET" \
        -n "$NAMESPACE" -o jsonpath='{.data.mysql-root-password}' | base64 -d)
    MYSQL_WLM_PASSWORD=$(kubectl get secret "$PASSWORDS_SECRET" \
        -n "$NAMESPACE" -o jsonpath='{.data.mysql-wlm-password}' | base64 -d)
    MYSQL_DMAPI_PASSWORD=$(kubectl get secret "$PASSWORDS_SECRET" \
        -n "$NAMESPACE" -o jsonpath='{.data.mysql-dmapi-password}' | base64 -d)
    RABBITMQ_WLM_PASSWORD=$(kubectl get secret "$PASSWORDS_SECRET" \
        -n "$NAMESPACE" -o jsonpath='{.data.rabbitmq-wlm-password}' | base64 -d)
    RABBITMQ_DMAPI_PASSWORD=$(kubectl get secret "$PASSWORDS_SECRET" \
        -n "$NAMESPACE" -o jsonpath='{.data.rabbitmq-dmapi-password}' | base64 -d)
else
    step "Generating passwords..."

    MYSQL_ROOT_PASSWORD=$(openssl rand -hex 20)
    MYSQL_WLM_PASSWORD=$(openssl rand -hex 20)
    MYSQL_DMAPI_PASSWORD=$(openssl rand -hex 20)
    RABBITMQ_WLM_PASSWORD=$(openssl rand -hex 20)
    RABBITMQ_DMAPI_PASSWORD=$(openssl rand -hex 20)

    step "Storing passwords in secret '$PASSWORDS_SECRET'..."
    kubectl delete secret "$PASSWORDS_SECRET" -n "$NAMESPACE" --ignore-not-found
    kubectl create secret generic "$PASSWORDS_SECRET" \
        -n "$NAMESPACE" \
        --from-literal=mysql-root-password="${MYSQL_ROOT_PASSWORD}" \
        --from-literal=mysql-wlm-password="${MYSQL_WLM_PASSWORD}" \
        --from-literal=mysql-dmapi-password="${MYSQL_DMAPI_PASSWORD}" \
        --from-literal=rabbitmq-wlm-password="${RABBITMQ_WLM_PASSWORD}" \
        --from-literal=rabbitmq-dmapi-password="${RABBITMQ_DMAPI_PASSWORD}"
    info "Passwords stored in secret '$PASSWORDS_SECRET'."
fi

# ---------- Step 5: Create MySQL credential secrets ----------

step "Creating MySQL credential secrets..."

# trilio-mysql-root: required by InnoDBCluster CR (rootUser, rootPassword, rootHost)
kubectl delete secret trilio-mysql-root -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic trilio-mysql-root \
    -n "$NAMESPACE" \
    --from-literal=rootUser=root \
    --from-literal=rootPassword="${MYSQL_ROOT_PASSWORD}" \
    --from-literal=rootHost='%'

# Per-service secrets used by the MySQL init job
kubectl delete secret trilio-mysql-wlm -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic trilio-mysql-wlm \
    -n "$NAMESPACE" \
    --from-literal=password="${MYSQL_WLM_PASSWORD}"

kubectl delete secret trilio-mysql-dmapi -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic trilio-mysql-dmapi \
    -n "$NAMESPACE" \
    --from-literal=password="${MYSQL_DMAPI_PASSWORD}"

info "MySQL credential secrets created."

# ---------- Step 6: Deploy MySQL InnoDB Cluster ----------

step "Deploying MySQL InnoDB Cluster (trilio-mysql, ${MYSQL_INSTANCES} instances)..."

# Build the InnoDBCluster CR from infra_inputs.yaml values.
# storageClassName and image are omitted when empty (operator picks defaults).
MYSQL_CR=$(cat <<CREOF
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
)
echo "$MYSQL_CR" | kubectl apply -f -

info "Waiting for MySQL InnoDB Cluster to be ready (8-12 minutes)..."
kubectl wait innodbcluster/trilio-mysql \
    -n "$NAMESPACE" \
    --for=condition=Ready \
    --timeout=20m

info "MySQL InnoDB Cluster ready."

# ---------- Step 7: Initialize MySQL databases and users ----------

step "Creating MySQL databases and users via init job..."

kubectl delete job trilio-mysql-init -n "$NAMESPACE" --ignore-not-found

# All shell variables below are expanded at script run time.
# Passwords are hex strings — safe to embed directly in SQL.
cat <<JOBEOF | kubectl apply -f -
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
          echo "Connecting to MySQL Router at trilio-mysql:6446..."
          mysql \
            -h trilio-mysql.${NAMESPACE}.svc.cluster.local \
            -P 6446 \
            -u root \
            -p"${MYSQL_ROOT_PASSWORD}" \
            --ssl-mode=PREFERRED \
            --connect-timeout=30 \
            -e "
          CREATE DATABASE IF NOT EXISTS workloadmgr
            CHARACTER SET utf8 COLLATE utf8_general_ci;
          CREATE DATABASE IF NOT EXISTS dmapi
            CHARACTER SET utf8 COLLATE utf8_general_ci;
          CREATE USER IF NOT EXISTS 'workloadmgr'@'%'
            IDENTIFIED BY '${MYSQL_WLM_PASSWORD}';
          CREATE USER IF NOT EXISTS 'dmapi'@'%'
            IDENTIFIED BY '${MYSQL_DMAPI_PASSWORD}';
          GRANT ALL PRIVILEGES ON workloadmgr.* TO 'workloadmgr'@'%';
          GRANT ALL PRIVILEGES ON dmapi.* TO 'dmapi'@'%';
          FLUSH PRIVILEGES;
          SELECT user, host FROM mysql.user WHERE user IN ('workloadmgr','dmapi');
          SHOW DATABASES;"
          echo "MySQL initialization complete."
JOBEOF

info "Waiting for MySQL init job to complete..."
kubectl wait job/trilio-mysql-init \
    -n "$NAMESPACE" \
    --for=condition=Complete \
    --timeout=10m

info "MySQL databases and users created."

# ---------- Step 8: Deploy RabbitMQ Cluster ----------

step "Deploying RabbitMQ cluster (trilio-rabbitmq, ${RABBIT_REPLICAS} replicas)..."

# Build quorum queue config block when enabled
RABBIT_QUORUM_CONF=""
if [ "$RABBIT_QUORUM" = "true" ] || [ "$RABBIT_QUORUM" = "True" ]; then
    RABBIT_QUORUM_CONF=$'\n          default_queue_type = quorum\n          raft.wal_max_size_bytes = 134217728\n          raft.segment_max_entries = 32768'
fi

# Build combined additional_config block
RABBIT_CONF_BLOCK=""
if [ -n "$RABBIT_QUORUM_CONF" ] || [ -n "$RABBIT_EXTRA_CONFIG" ]; then
    RABBIT_CONF_BLOCK="  rabbitmq:
    additionalConfig: |
$(echo "${RABBIT_QUORUM_CONF}${RABBIT_EXTRA_CONFIG}" | sed 's/^/      /')"
fi

RABBIT_CR=$(cat <<CREOF
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
${RABBIT_CONF_BLOCK}
  override:
    statefulSet:
      spec:
        template:
          spec:
            nodeSelector:
              triliovault-control-plane: "enabled"
CREOF
)
echo "$RABBIT_CR" | kubectl apply -f -

info "Waiting for RabbitMQ cluster to be ready (3-5 minutes)..."
kubectl wait rabbitmqcluster/trilio-rabbitmq \
    -n "$NAMESPACE" \
    --for=condition=Ready \
    --timeout=10m

info "RabbitMQ cluster ready."

# ---------- Step 9: Initialize RabbitMQ vhosts and users ----------

step "Creating RabbitMQ vhosts and users via init job..."

# rabbitmq-cluster-operator stores admin credentials in '<name>-default-user' secret
RABBITMQ_ADMIN_USER=$(kubectl get secret trilio-rabbitmq-default-user \
    -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
RABBITMQ_ADMIN_PASS=$(kubectl get secret trilio-rabbitmq-default-user \
    -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

kubectl delete job trilio-rabbitmq-init -n "$NAMESPACE" --ignore-not-found

# Shell variables are expanded below — passwords are hex strings, safe to embed.
cat <<JOBEOF | kubectl apply -f -
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

          echo "Creating vhost: workloadmgr"
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/vhosts/workloadmgr"

          echo "Creating vhost: dmapi"
          curl -sf -u "\${AUTH}" -X PUT "\${MGMT}/api/vhosts/dmapi"

          echo "Creating user: workloadmgr"
          curl -sf -u "\${AUTH}" \
            -X PUT "\${MGMT}/api/users/workloadmgr" \
            -H "Content-Type: application/json" \
            -d '{"password":"${RABBITMQ_WLM_PASSWORD}","tags":""}'

          echo "Creating user: dmapi"
          curl -sf -u "\${AUTH}" \
            -X PUT "\${MGMT}/api/users/dmapi" \
            -H "Content-Type: application/json" \
            -d '{"password":"${RABBITMQ_DMAPI_PASSWORD}","tags":""}'

          echo "Setting permissions: workloadmgr on vhost workloadmgr"
          curl -sf -u "\${AUTH}" \
            -X PUT "\${MGMT}/api/permissions/workloadmgr/workloadmgr" \
            -H "Content-Type: application/json" \
            -d '{"configure":".*","write":".*","read":".*"}'

          echo "Setting permissions: dmapi on vhost dmapi"
          curl -sf -u "\${AUTH}" \
            -X PUT "\${MGMT}/api/permissions/dmapi/dmapi" \
            -H "Content-Type: application/json" \
            -d '{"configure":".*","write":".*","read":".*"}'

          echo "RabbitMQ initialization complete."
JOBEOF

info "Waiting for RabbitMQ init job to complete..."
kubectl wait job/trilio-rabbitmq-init \
    -n "$NAMESPACE" \
    --for=condition=Complete \
    --timeout=5m

info "RabbitMQ vhosts and users created."

# ---------- Step 10: Create NodePort services for compute node access ----------

step "Creating NodePort services for compute node access..."

# MySQL NodePort — maps external port 30306 to MySQL Router port 6446
# Compute nodes use: mysql+pymysql://user:pass@<node-ip>:30306/db
if ! kubectl get service trilio-mysql-nodeport -n "$NAMESPACE" &>/dev/null; then
    kubectl expose service trilio-mysql \
        --name=trilio-mysql-nodeport \
        --type=NodePort \
        --port=6446 \
        --target-port=6446 \
        -n "$NAMESPACE"
    kubectl patch service trilio-mysql-nodeport -n "$NAMESPACE" \
        --type='json' \
        -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30306}]'
    info "MySQL NodePort created: 30306 -> 6446 (MySQL Router)"
else
    info "MySQL NodePort service already exists."
fi

# RabbitMQ NodePort — maps external port 30672 to AMQP port 5672
# Compute nodes use: rabbit://user:pass@<node-ip>:30672/vhost
if ! kubectl get service trilio-rabbitmq-nodeport -n "$NAMESPACE" &>/dev/null; then
    kubectl expose service trilio-rabbitmq \
        --name=trilio-rabbitmq-nodeport \
        --type=NodePort \
        --port=5672 \
        --target-port=5672 \
        -n "$NAMESPACE"
    kubectl patch service trilio-rabbitmq-nodeport -n "$NAMESPACE" \
        --type='json' \
        -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30672}]'
    info "RabbitMQ NodePort created: 30672 -> 5672 (AMQP)"
else
    info "RabbitMQ NodePort service already exists."
fi

# ---------- Summary ----------

MYSQL_HOST="trilio-mysql.${NAMESPACE}.svc.cluster.local"
RABBITMQ_HOST="trilio-rabbitmq.${NAMESPACE}.svc.cluster.local"

echo ""
echo "=================================================="
info "Infrastructure deployment complete."
echo ""
echo "  MySQL    : ${MYSQL_HOST}:6446  (InnoDB Cluster, 3 instances)"
echo "  RabbitMQ : ${RABBITMQ_HOST}:5672  (cluster, 3 replicas)"
echo ""
echo "  NodePort (for compute nodes):"
echo "    MySQL    : <node-ip>:30306"
echo "    RabbitMQ : <node-ip>:30672"
echo ""
echo "  Credentials stored in secret: ${PASSWORDS_SECRET}"
echo ""
echo "  Next step:"
echo "    bash generate_overrides.sh"
echo "=================================================="
