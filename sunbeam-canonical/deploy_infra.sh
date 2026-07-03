#!/bin/bash
# deploy_infra.sh
#
# Deploys T4O infrastructure (MySQL InnoDB Cluster + RabbitMQ Cluster)
# on Sunbeam (MicroK8s) using infra_inputs.yaml.
#
# Skips MySQL or RabbitMQ with a warning if they already exist.
# To reinstall from scratch: bash uninstall_infra.sh
#
# Prerequisites:
#   - kubectl configured against the MicroK8s cluster
#   - MySQL Operator and RabbitMQ Cluster Operator installed
#   - trilio-openstack namespace exists (run bash prepare.sh first)
#
# Usage:
#   bash deploy_infra.sh [--inputs-file infra_inputs.yaml]
#
# Options:
#   --inputs-file   Path to infra_inputs.yaml (default: same dir as this script)
#   -h, --help      Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUTS_FILE="${SCRIPT_DIR}/infra_inputs.yaml"
NAMESPACE="trilio-openstack"   # must match ctlplane-scripts/deploy_infra.sh

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)  INPUTS_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[ -f "$INPUTS_FILE" ] || err "infra_inputs.yaml not found: $INPUTS_FILE"

echo "=================================================="
echo " T4O Sunbeam — Deploy Infrastructure"
echo " Namespace  : $NAMESPACE"
echo " Inputs     : $INPUTS_FILE"
echo "=================================================="

# ---------- Check if already deployed ----------

MYSQL_EXISTS=false
RABBIT_EXISTS=false

step "Checking existing infrastructure..."

if kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" &>/dev/null; then
    MYSQL_STATUS=$(kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" \
        -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "Unknown")
    warn "MySQL InnoDB Cluster 'trilio-mysql' already exists (status: ${MYSQL_STATUS}) — skipping."
    warn "To reinstall: bash uninstall_infra.sh"
    MYSQL_EXISTS=true
fi

if kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" &>/dev/null; then
    RABBIT_STATUS=$(kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    warn "RabbitMQ cluster 'trilio-rabbitmq' already exists (status: ${RABBIT_STATUS}) — skipping."
    warn "To reinstall: bash uninstall_infra.sh"
    RABBIT_EXISTS=true
fi

if [ "$MYSQL_EXISTS" = true ] && [ "$RABBIT_EXISTS" = true ]; then
    info "Both MySQL and RabbitMQ are already deployed — nothing to do."
    exit 0
fi

# ---------- Deploy ----------

bash "${SCRIPT_DIR}/ctlplane-scripts/deploy_infra.sh" --inputs-file "${INPUTS_FILE}"

echo ""
echo "=================================================="
info "Infrastructure deployment complete."
echo ""
echo "  Next step:"
echo "    bash deploy_ctlplane.sh"
echo "=================================================="
