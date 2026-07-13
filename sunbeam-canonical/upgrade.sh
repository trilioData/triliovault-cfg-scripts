#!/usr/bin/env bash
# upgrade.sh — Upgrade TrilioVault on Sunbeam Canonical OpenStack
#
# Upgrades the control plane k8s charms (trilio-wlm-k8s, trilio-dm-api-k8s),
# the data plane subordinate (trilio-data-mover), and the Horizon plugin.
#
# Usage:
#   bash upgrade.sh --trilio-version 6.3.1
#
# Options:
#   --trilio-version <VER>    Target Trilio version (required)
#   --ctlplane-model <MODEL>  k8s model name (default: openstack)
#   --dataplane-model <MODEL> machine model name (default: openstack-machines)
#   --skip-horizon            Skip horizon plugin upgrade
#   --horizon-image <IMAGE>   Horizon OCI image for new version

set -euo pipefail

CTLPLANE_MODEL="${CTLPLANE_MODEL:-openstack}"
DATAPLANE_MODEL="${DATAPLANE_MODEL:-openstack-machines}"
TRILIO_VERSION="${TRILIO_VERSION:-}"
SKIP_HORIZON="${SKIP_HORIZON:-false}"
HORIZON_IMAGE="${HORIZON_IMAGE:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --trilio-version)  TRILIO_VERSION="$2";  shift 2 ;;
    --ctlplane-model)  CTLPLANE_MODEL="$2";  shift 2 ;;
    --dataplane-model) DATAPLANE_MODEL="$2"; shift 2 ;;
    --skip-horizon)    SKIP_HORIZON=true;    shift   ;;
    --horizon-image)   HORIZON_IMAGE="$2";   shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$TRILIO_VERSION" ]]; then
  echo "Error: --trilio-version is required"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Step 1: Upgrade control plane charms ---
log "Upgrading trilio-wlm-k8s to version $TRILIO_VERSION in model $CTLPLANE_MODEL"
juju switch "$CTLPLANE_MODEL"
juju refresh trilio-wlm-k8s  --channel stable
juju refresh trilio-dm-api-k8s --channel stable

log "Waiting for control plane to become active post-upgrade..."
juju wait-for application trilio-wlm-k8s  --query='status=="active"' --timeout=10m
juju wait-for application trilio-dm-api-k8s --query='status=="active"' --timeout=10m

# --- Step 2: Upgrade data plane ---
log "Upgrading trilio-data-mover to version $TRILIO_VERSION in model $DATAPLANE_MODEL"
juju switch "$DATAPLANE_MODEL"
juju config trilio-data-mover trilio-version="$TRILIO_VERSION"
juju refresh trilio-data-mover --channel stable

log "Waiting for data plane to become active post-upgrade..."
juju wait-for application trilio-data-mover --query='status=="active"' --timeout=10m

# --- Step 3: Upgrade Horizon plugin ---
if [[ "$SKIP_HORIZON" != "true" ]]; then
  if [[ -z "$HORIZON_IMAGE" ]]; then
    HORIZON_IMAGE="docker.io/trilio/trilio-horizon-plugin-canonical:${TRILIO_VERSION}-2024.1"
  fi
  log "Attaching upgraded Horizon plugin image: $HORIZON_IMAGE"
  juju switch "$CTLPLANE_MODEL"
  juju attach-resource horizon-k8s horizon-image="$HORIZON_IMAGE" -m "$CTLPLANE_MODEL"
  log "Horizon plugin upgraded."
else
  log "Skipping Horizon plugin upgrade (--skip-horizon set)."
fi

log "TrilioVault upgrade to $TRILIO_VERSION complete."
