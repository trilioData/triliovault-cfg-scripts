#!/bin/bash
# uninstall_ctlplane.sh
#
# Removes the T4O control plane Helm release from the trilio-openstack namespace.
#
# Usage:
#   bash scripts/uninstall_ctlplane.sh
#
# Options:
#   --yes   Skip confirmation prompts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/uninstall_ctlplane.log"
exec > >(tee "$LOG_FILE") 2>&1
NAMESPACE="${NAMESPACE:-trilio-openstack}"
RELEASE_NAME="${RELEASE_NAME:-tvo}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

AUTO_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) AUTO_CONFIRM=true; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

echo "=================================================="
echo " T4O Control Plane — Uninstall"
echo " Namespace : ${NAMESPACE}"
echo " Release   : ${RELEASE_NAME}"
echo " Log       : $LOG_FILE"
echo "=================================================="
echo ""
warn "This will remove all T4O control plane services (wlm, datamover-api)."
echo ""

if [ "$AUTO_CONFIRM" = false ]; then
    read -rp "  Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { info "Aborted."; exit 0; }
fi

if helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" &>/dev/null; then
    helm uninstall "${RELEASE_NAME}" --namespace "${NAMESPACE}"
    info "Helm release '${RELEASE_NAME}' removed."
else
    info "Helm release '${RELEASE_NAME}' not found in namespace '${NAMESPACE}' — skipping."
fi

echo ""
read -rp "  Delete namespace '${NAMESPACE}'? [y/N] " del_ns
if [[ "$del_ns" =~ ^[yY]$ ]]; then
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found
    info "Namespace '${NAMESPACE}' deleted."
fi

echo ""
echo "=================================================="
info "T4O control plane uninstall complete."
echo "=================================================="
