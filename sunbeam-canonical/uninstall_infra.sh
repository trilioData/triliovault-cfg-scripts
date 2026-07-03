#!/bin/bash
# uninstall_infra.sh
#
# Removes TrilioVault infrastructure (MySQL InnoDB Cluster + RabbitMQ cluster)
# from the trilio-openstack namespace.
#
# WARNING: This deletes all persistent data (PVCs) and passwords (secrets).
#          Run deploy_ctlplane.sh again after this to redeploy from scratch.
#
# What this script removes:
#   - MySQL InnoDB Cluster (trilio-mysql) and its PVCs
#   - RabbitMQ cluster (trilio-rabbitmq) and its PVCs
#   - Passwords secret (trilio-infra-passwords)
#   - Per-service credential secrets (trilio-mysql-root, trilio-mysql-wlm, etc.)
#   - NodePort services (trilio-mysql-nodeport, trilio-rabbitmq-nodeport)
#   - MySQL init and RabbitMQ init jobs
#
# The trilio-openstack namespace itself and T4O control plane pods are NOT removed.
# To uninstall T4O control plane: helm uninstall tvo --namespace trilio-openstack
#
# Usage:
#   bash uninstall_infra.sh [--yes]
#
# Options:
#   --yes   Skip confirmation prompt

set -euo pipefail

NAMESPACE="trilio-openstack"
AUTO_CONFIRM=false

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${GREEN}==>${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)     AUTO_CONFIRM=true; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

echo "=================================================="
echo " TrilioVault Infrastructure — Uninstall"
echo " Namespace : $NAMESPACE"
echo "=================================================="
echo ""
warn "This will permanently delete MySQL and RabbitMQ data and all passwords."
warn "You will need to re-run deploy_ctlplane.sh to redeploy."
echo ""

if [ "$AUTO_CONFIRM" = false ]; then
    read -r -p "  Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { info "Aborted."; exit 0; }
fi

# ---------- Remove init jobs ----------

step "Removing init jobs..."
kubectl delete job trilio-mysql-init    -n "$NAMESPACE" --ignore-not-found
kubectl delete job trilio-rabbitmq-init -n "$NAMESPACE" --ignore-not-found
info "Init jobs removed."

# ---------- Remove NodePort services ----------

step "Removing NodePort services..."
kubectl delete service trilio-mysql-nodeport    -n "$NAMESPACE" --ignore-not-found
kubectl delete service trilio-rabbitmq-nodeport -n "$NAMESPACE" --ignore-not-found
info "NodePort services removed."

# ---------- Remove MySQL InnoDB Cluster ----------

step "Removing MySQL InnoDB Cluster (trilio-mysql)..."

if kubectl get innodbcluster trilio-mysql -n "$NAMESPACE" &>/dev/null; then
    kubectl delete innodbcluster trilio-mysql -n "$NAMESPACE"
    info "Waiting for MySQL pods to terminate..."
    kubectl wait pods -n "$NAMESPACE" -l mysql.oracle.com/cluster=trilio-mysql \
        --for=delete --timeout=5m 2>/dev/null || true
    kubectl delete pvc -n "$NAMESPACE" -l mysql.oracle.com/cluster=trilio-mysql \
        --ignore-not-found
    info "MySQL InnoDB Cluster and PVCs removed."
else
    info "MySQL InnoDB Cluster 'trilio-mysql' not found — skipping."
fi

# ---------- Remove RabbitMQ Cluster ----------

step "Removing RabbitMQ cluster (trilio-rabbitmq)..."

if kubectl get rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE" &>/dev/null; then
    kubectl delete rabbitmqcluster trilio-rabbitmq -n "$NAMESPACE"
    info "Waiting for RabbitMQ pods to terminate..."
    kubectl wait pods -n "$NAMESPACE" -l app.kubernetes.io/name=trilio-rabbitmq \
        --for=delete --timeout=5m 2>/dev/null || true
    kubectl delete pvc -n "$NAMESPACE" -l app.kubernetes.io/name=trilio-rabbitmq \
        --ignore-not-found
    info "RabbitMQ cluster and PVCs removed."
else
    info "RabbitMQ cluster 'trilio-rabbitmq' not found — skipping."
fi

# ---------- Remove secrets ----------

step "Removing credential secrets..."
for SECRET in trilio-infra-passwords trilio-mysql-root trilio-mysql-wlm trilio-mysql-dmapi \
              trilio-rabbitmq-default-user; do
    kubectl delete secret "$SECRET" -n "$NAMESPACE" --ignore-not-found
done
info "Credential secrets removed."

echo ""
echo "=================================================="
info "Infrastructure uninstall complete."
echo ""
echo "  To redeploy infrastructure and T4O control plane:"
echo "    bash deploy_ctlplane.sh"
echo "=================================================="
