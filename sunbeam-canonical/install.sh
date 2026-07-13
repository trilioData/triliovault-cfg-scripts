#!/usr/bin/env bash
# install.sh — Deploy TrilioVault on Sunbeam Canonical OpenStack
#
# Prerequisites:
#   - Sunbeam bootstrap complete (openstack + openstack-machines models exist)
#   - juju CLI installed and logged in to the Sunbeam controller
#   - NFS share or S3 bucket prepared for backup target
#
# Usage:
#   bash install.sh [OPTIONS]
#
# Options:
#   --nfs-shares <SHARE>      NFS share for backup, e.g. 192.168.1.10:/backup
#   --trilio-version <VER>    Specific Trilio version, e.g. 6.2.1 (default: latest)
#   --backup-target nfs|s3    Backup target type (default: nfs)
#   --ctlplane-model <MODEL>  k8s model name (default: openstack)
#   --dataplane-model <MODEL> machine model name (default: openstack-machines)
#   --skip-horizon            Skip horizon plugin attachment
#   --horizon-image <IMAGE>   Horizon OCI image (default: docker.io/trilio/trilio-horizon-canonical:latest)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CTLPLANE_MODEL="${CTLPLANE_MODEL:-openstack}"
DATAPLANE_MODEL="${DATAPLANE_MODEL:-openstack-machines}"
TRILIO_VERSION="${TRILIO_VERSION:-}"
BACKUP_TARGET="${BACKUP_TARGET:-nfs}"
NFS_SHARES="${NFS_SHARES:-}"
SKIP_HORIZON="${SKIP_HORIZON:-false}"
HORIZON_IMAGE="${HORIZON_IMAGE:-docker.io/trilio/trilio-horizon-canonical:latest}"

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case $1 in
    --nfs-shares)      NFS_SHARES="$2";      shift 2 ;;
    --trilio-version)  TRILIO_VERSION="$2";  shift 2 ;;
    --backup-target)   BACKUP_TARGET="$2";   shift 2 ;;
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
juju offer rabbitmq:amqp           || true
juju offer keystone:identity-credentials || true

# --- Step 2: Deploy control plane bundle ---
log "Deploying TrilioVault control plane into model: $CTLPLANE_MODEL"
BUNDLE_ARGS=""
if [[ -n "$NFS_SHARES" ]]; then
  BUNDLE_ARGS="$BUNDLE_ARGS --config trilio-wlm-k8s.nfs-shares=$NFS_SHARES"
fi
if [[ "$BACKUP_TARGET" != "nfs" ]]; then
  BUNDLE_ARGS="$BUNDLE_ARGS --config trilio-wlm-k8s.backup-target-type=$BACKUP_TARGET"
fi
# shellcheck disable=SC2086
juju deploy "$SCRIPT_DIR/trilio-ctlplane-bundle.yaml" $BUNDLE_ARGS

log "Waiting for control plane applications to become active..."
juju wait-for application trilio-wlm-k8s  --query='status=="active"' --timeout=10m
juju wait-for application trilio-dmapi-k8s --query='status=="active"' --timeout=10m

# --- Step 3: Deploy data plane bundle ---
log "Deploying TrilioVault data plane into model: $DATAPLANE_MODEL"
juju switch "$DATAPLANE_MODEL"

DP_BUNDLE_ARGS=""
if [[ -n "$TRILIO_VERSION" ]]; then
  DP_BUNDLE_ARGS="$DP_BUNDLE_ARGS --config trilio-data-mover-sunbeam.trilio-version=$TRILIO_VERSION"
fi
if [[ -n "$NFS_SHARES" ]]; then
  DP_BUNDLE_ARGS="$DP_BUNDLE_ARGS --config trilio-data-mover-sunbeam.nfs-shares=$NFS_SHARES"
fi
# shellcheck disable=SC2086
juju deploy "$SCRIPT_DIR/trilio-dataplane-bundle.yaml" $DP_BUNDLE_ARGS

log "Waiting for data plane applications to become active..."
juju wait-for application trilio-data-mover-sunbeam --query='status=="active"' --timeout=10m

# --- Step 4: Attach Horizon plugin (optional) ---
if [[ "$SKIP_HORIZON" != "true" ]]; then
  log "Attaching Trilio Horizon plugin image..."
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
