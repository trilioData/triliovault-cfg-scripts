#!/bin/bash
# deploy_infra.sh
#
# Deploys T4O infrastructure (MySQL InnoDB Cluster + RabbitMQ Cluster)
# on Sunbeam (MicroK8s) using infra_inputs.yaml.
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

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inputs-file)  INPUTS_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[ -f "$INPUTS_FILE" ] || err "infra_inputs.yaml not found: $INPUTS_FILE"

info "Using inputs: $INPUTS_FILE"
exec bash "${SCRIPT_DIR}/ctlplane-scripts/deploy_infra.sh" --inputs-file "${INPUTS_FILE}"
