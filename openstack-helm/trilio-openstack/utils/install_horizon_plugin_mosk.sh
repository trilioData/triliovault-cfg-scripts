#!/bin/bash

# Install (or roll back) the Trilio Horizon plugin on MOSK by overriding the Horizon image
# in the OpenStackDeployment (OsDpl).
#
# Why a pre-pull: the plugin image is private and MOSK's Horizon deployment has no pull secret
# and pulls with IfNotPresent. MOSK 26.2 nodes run containerd and are not reachable over SSH,
# so the image is pulled onto every control node by a short-lived DaemonSet that uses the
# triliovault-image-registry secret (created by create_image_pull_secret.sh).
#
# Usage:
#   ./install_horizon_plugin_mosk.sh <horizon_plugin_image>
#   ./install_horizon_plugin_mosk.sh --rollback
#
# Example:
#   ./install_horizon_plugin_mosk.sh docker.io/trilio/trilio-horizon-plugin-helm:6.2.1-mosk26.2
#
# Use a new image tag for every rebuild: with IfNotPresent, a rebuilt image under an old tag
# never reaches nodes that already cached it.
#
# Optional environment variables:
#   OSDPL_NAME   OsDpl name (default: the only OsDpl in the namespace)
#   NAMESPACE    OpenStack namespace (default: openstack)
#   PULL_SECRET  image pull secret in NAMESPACE (default: triliovault-image-registry)
#   TIMEOUT      seconds to wait for each phase (default: 1800)

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstack}"
PULL_SECRET="${PULL_SECRET:-triliovault-image-registry}"
TIMEOUT="${TIMEOUT:-1800}"
PREPULL_DS="trilio-horizon-prepull"
NODE_SELECTOR_KEY="openstack-control-plane"

usage() {
    sed -n '/^# Usage:/,/^# Example:/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^Example:'
    exit 1
}

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Poll until "$@" succeeds or TIMEOUT expires. Never blocks on a watch.
wait_for() {
    local desc="$1"; shift
    local start=$SECONDS
    until "$@"; do
        if (( SECONDS - start >= TIMEOUT )); then
            die "timed out after ${TIMEOUT}s waiting for: $desc"
        fi
        sleep 10
    done
}

osdpl_field() {
    kubectl -n "$NAMESPACE" get osdplst "$OSDPL_NAME" -o jsonpath="{.status.osdpl.$1}" 2>/dev/null
}

osdpl_applied() { [[ "$(osdpl_field state)" == "APPLIED" ]]; }

current_override() {
    kubectl -n "$NAMESPACE" get osdpl "$OSDPL_NAME" \
        -o jsonpath='{.spec.services.dashboard.horizon.values.images.tags.horizon}' 2>/dev/null
}

horizon_image() {
    kubectl -n "$NAMESPACE" get deploy horizon -o jsonpath='{.spec.template.spec.containers[0].image}'
}

# Wait for the OsDpl controller to apply a change: the status timestamp moves past the value
# recorded before the patch AND the state returns to APPLIED.
osdpl_reapplied() {
    local ts state
    ts="$(osdpl_field timestamp)"; state="$(osdpl_field state)"
    log "  OsDpl state=${state:-?} lcm=$(osdpl_field lcm_progress) health=$(osdpl_field health)"
    [[ "$ts" != "$TS_BEFORE" && "$state" == "APPLIED" ]]
}

wait_for_horizon_rollout() {
    log "Waiting for the Horizon deployment to roll out..."
    if ! kubectl -n "$NAMESPACE" rollout status deploy/horizon --timeout="${TIMEOUT}s"; then
        echo
        echo "Horizon rollout did not complete. New pods:"
        kubectl -n "$NAMESPACE" get pods -o wide | grep '^horizon-' | grep -v -- '-db-' || true
        local bad
        bad=$(kubectl -n "$NAMESPACE" get pods --no-headers | awk '/^horizon-/ && !/-db-/ && $2 != "1/1" {print $1; exit}')
        if [[ -n "$bad" ]]; then
            echo "--- last log lines of $bad:"
            kubectl -n "$NAMESPACE" logs "$bad" -c horizon --tail=25 2>/dev/null \
                || kubectl -n "$NAMESPACE" logs "$bad" -c horizon --previous --tail=25 2>/dev/null || true
        fi
        echo
        echo "The old Horizon pods keep serving until the new ones are Ready."
        echo "To go back to the stock Horizon image: $0 --rollback"
        exit 1
    fi
}

cleanup_prepull() {
    kubectl -n "$NAMESPACE" delete ds "$PREPULL_DS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- arguments / preflight
[[ $# -eq 1 ]] || usage
ACTION="install"; IMG=""
case "$1" in
    -h|--help) usage ;;
    --rollback) ACTION="rollback" ;;
    -*) usage ;;
    *) IMG="$1" ;;
esac

command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed."

if [[ -z "${OSDPL_NAME:-}" ]]; then
    mapfile -t names < <(kubectl -n "$NAMESPACE" get osdpl -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    [[ ${#names[@]} -eq 1 ]] || die "found ${#names[@]} OsDpl objects in '$NAMESPACE'; set OSDPL_NAME."
    OSDPL_NAME="${names[0]}"
fi
kubectl -n "$NAMESPACE" get osdpl "$OSDPL_NAME" >/dev/null || die "OsDpl '$OSDPL_NAME' not found in '$NAMESPACE'."
log "OsDpl: $NAMESPACE/$OSDPL_NAME, current Horizon image: $(horizon_image)"

# Never patch while the controller is applying an earlier change.
if ! osdpl_applied; then
    log "OsDpl is $(osdpl_field state); waiting for APPLIED before changing it..."
    wait_for "OsDpl $OSDPL_NAME to be APPLIED" osdpl_applied
fi

# ---------------------------------------------------------------- rollback
if [[ "$ACTION" == "rollback" ]]; then
    if [[ -z "$(current_override)" ]]; then
        log "No Horizon image override in the OsDpl; nothing to roll back."
        exit 0
    fi
    TS_BEFORE="$(osdpl_field timestamp)"
    log "Removing the Horizon image override ($(current_override))..."
    kubectl -n "$NAMESPACE" patch osdpl "$OSDPL_NAME" --type json \
        -p '[{"op":"remove","path":"/spec/services/dashboard/horizon/values/images/tags/horizon"}]'
    wait_for "OsDpl $OSDPL_NAME to apply the rollback" osdpl_reapplied
    wait_for_horizon_rollout
    log "Rolled back. Horizon image: $(horizon_image)"
    exit 0
fi

# ---------------------------------------------------------------- install
kubectl -n "$NAMESPACE" get secret "$PULL_SECRET" >/dev/null 2>&1 \
    || die "pull secret '$PULL_SECRET' not found in '$NAMESPACE'; run ./create_image_pull_secret.sh first."

if [[ "$(current_override)" == "$IMG" && "$(horizon_image)" == "$IMG" ]]; then
    log "Horizon already uses $IMG; nothing to do."
    exit 0
fi

# 1. Pre-pull the image on every node Horizon can run on.
trap cleanup_prepull EXIT
cleanup_prepull
log "Pre-pulling $IMG on all '$NODE_SELECTOR_KEY=enabled' nodes..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $PREPULL_DS
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels: {app: $PREPULL_DS}
  template:
    metadata:
      labels: {app: $PREPULL_DS}
    spec:
      nodeSelector: {$NODE_SELECTOR_KEY: enabled}
      imagePullSecrets: [{name: $PULL_SECRET}]
      terminationGracePeriodSeconds: 0
      containers:
      - name: prepull
        image: "$IMG"
        command: ["sleep", "3600"]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
if ! kubectl -n "$NAMESPACE" rollout status ds/"$PREPULL_DS" --timeout="${TIMEOUT}s"; then
    echo "Image pre-pull failed. Pod status:"
    kubectl -n "$NAMESPACE" get pods -l app="$PREPULL_DS" -o wide || true
    kubectl -n "$NAMESPACE" get events --field-selector reason=Failed 2>/dev/null | grep "$PREPULL_DS" | tail -5 || true
    die "could not pull $IMG (check the tag and the '$PULL_SECRET' credentials)."
fi
cleanup_prepull
trap - EXIT
log "Image cached on all control nodes."

# 2. Point Horizon at the plugin image.
TS_BEFORE="$(osdpl_field timestamp)"
log "Setting the Horizon image override in OsDpl $OSDPL_NAME..."
kubectl -n "$NAMESPACE" patch osdpl "$OSDPL_NAME" --type merge -p \
    "{\"spec\":{\"services\":{\"dashboard\":{\"horizon\":{\"values\":{\"images\":{\"tags\":{\"horizon\":\"$IMG\"}}}}}}}}"

# 3. Wait for the controller to apply it, then for the Horizon pods to roll.
wait_for "OsDpl $OSDPL_NAME to apply the new Horizon image" osdpl_reapplied
[[ "$(horizon_image)" == "$IMG" ]] || die "OsDpl is APPLIED but deploy/horizon still uses $(horizon_image)."
wait_for_horizon_rollout

# 4. Verify the plugin is loaded in a running pod.
POD=$(kubectl -n "$NAMESPACE" get pods --no-headers | awk '/^horizon-/ && !/-db-/ && $2 == "1/1" {print $1; exit}')
ENABLED=$(kubectl -n "$NAMESPACE" exec "$POD" -c horizon -- sh -c \
    'ls /var/lib/openstack/lib/python3*/site-packages/openstack_dashboard/enabled/ 2>/dev/null | grep -c "_tvault_"' || true)
log "Horizon pods:"
kubectl -n "$NAMESPACE" get pods -o wide | grep '^horizon-' | grep -v -- '-db-'
if [[ "${ENABLED:-0}" -gt 0 ]]; then
    log "Trilio Horizon plugin installed ($ENABLED panel files enabled in $POD)."
    echo "Log out of Horizon and back in to see the Backups tab."
else
    die "Horizon rolled out, but no Trilio panel files were found in $POD."
fi
