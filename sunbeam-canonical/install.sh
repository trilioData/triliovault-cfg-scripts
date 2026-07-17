#!/usr/bin/env bash
# install.sh — Deploy TrilioVault on Sunbeam Canonical OpenStack
#
# Prerequisites:
#   - Sunbeam bootstrap complete (openstack + openstack-machines models exist)
#   - juju CLI installed and logged in to the Sunbeam controller
#
# Usage:
#   bash install.sh [OPTIONS]
#
# Options:
#   --trilio-version <VER>    Specific Trilio version, e.g. 6.2.1 (default: latest)
#   --ctlplane-model <MODEL>  k8s model name (default: openstack)
#   --dataplane-model <MODEL> machine model name (default: openstack-machines)
#   --skip-horizon            Skip horizon plugin attachment
#   --horizon-image <IMAGE>   Horizon OCI image override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CTLPLANE_MODEL="${CTLPLANE_MODEL:-openstack}"
DATAPLANE_MODEL="${DATAPLANE_MODEL:-openstack-machines}"
TRILIO_VERSION="${TRILIO_VERSION:-}"
SKIP_HORIZON="${SKIP_HORIZON:-false}"
HORIZON_IMAGE="${HORIZON_IMAGE:-}"

# Parse CLI args
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

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Step 1: Offer cross-model relations from the k8s model ---
log "Offering cross-model relations from model: $CTLPLANE_MODEL"
juju switch "$CTLPLANE_MODEL"
juju offer rabbitmq:amqp                     || true
juju offer keystone:identity-credentials     || true

# --- Step 2: Deploy control plane bundle ---
log "Deploying TrilioVault control plane into model: $CTLPLANE_MODEL"
juju deploy "$SCRIPT_DIR/trilio-ctlplane-bundle.yaml"

log "Waiting for control plane applications to become active..."
juju wait-for application trilio-wlm-k8s    --query='status=="active"' --timeout=10m
juju wait-for application trilio-dm-api-k8s --query='status=="active"' --timeout=10m
juju wait-for application trilio-dms-k8s    --query='status=="active"' --timeout=10m

# --- Step 2b: CA certificate relation (TLS) ---
# Relates WLM to Keystone's CA cert distributor so Python's requests library
# trusts internal HTTPS endpoints. Safe to run even if cluster uses plain HTTP
# (the relation will simply carry no data).
log "Relating trilio-wlm-k8s to keystone CA cert distributor..."
juju relate trilio-wlm-k8s:receive-ca-cert keystone:send-ca-cert || true

# --- Step 3: Deploy data plane bundle ---
log "Deploying TrilioVault data plane into model: $DATAPLANE_MODEL"
juju switch "$DATAPLANE_MODEL"

DP_BUNDLE_ARGS=""
if [[ -n "$TRILIO_VERSION" ]]; then
  DP_BUNDLE_ARGS="$DP_BUNDLE_ARGS --config trilio-data-mover.trilio-version=$TRILIO_VERSION"
fi
# shellcheck disable=SC2086
juju deploy "$SCRIPT_DIR/trilio-dataplane-bundle.yaml" $DP_BUNDLE_ARGS

log "Waiting for data plane applications to become active..."
juju wait-for application trilio-data-mover --query='status=="active"' --timeout=10m

# --- Step 4: Attach Horizon plugin (optional) ---
if [[ "$SKIP_HORIZON" != "true" ]]; then
  if [[ -z "$HORIZON_IMAGE" ]]; then
    if [[ -z "$TRILIO_VERSION" ]]; then
      log "WARNING: --trilio-version not set; cannot determine horizon image tag."
      log "         Re-run with --trilio-version <VER> or --horizon-image <IMAGE>,"
      log "         or use --skip-horizon to omit the plugin."
      log "Skipping Horizon plugin attachment."
      SKIP_HORIZON=true
    else
      HORIZON_IMAGE="docker.io/trilio/trilio-horizon-plugin-canonical:${TRILIO_VERSION}-2024.1"
    fi
  fi
  log "Attaching Trilio Horizon plugin image: $HORIZON_IMAGE"
  juju switch "$CTLPLANE_MODEL"
  juju attach-resource horizon-k8s horizon-image="$HORIZON_IMAGE" -m "$CTLPLANE_MODEL"
  log "Horizon plugin attached. Horizon will reload automatically."
else
  log "Skipping Horizon plugin (--skip-horizon set)."
fi

log "TrilioVault installation complete."
log ""
log "Verify with:"
log "  juju switch $CTLPLANE_MODEL && juju status"
log "  juju switch $DATAPLANE_MODEL && juju status"
