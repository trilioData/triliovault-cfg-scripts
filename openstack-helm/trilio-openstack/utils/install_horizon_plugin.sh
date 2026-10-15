#!/bin/bash

# Install (or roll back) the Trilio Horizon plugin on OpenStack-Helm by overriding the Horizon
# image in the horizon Helm release. For MOSK use install_horizon_plugin_mosk.sh instead.
#
# The plugin image is private and the OpenStack-Helm Horizon pods have no pull secret. The script
# copies the T4O registry secret (created by create_image_pull_secret.sh) into the OpenStack
# namespace and adds it to the imagePullSecrets of the horizon ServiceAccount, so every new
# Horizon pod gets it. The chart's ServiceAccount does not set imagePullSecrets, so later helm
# upgrades keep the entry. (The chart's own registry option would put the registry password into
# the horizon release values.) Pre-pulling the image is not enough: from Kubernetes 1.35 the
# kubelet only lets a pod use a cached private image if the pod has the credentials it was
# pulled with.
#
# Usage:
#   HORIZON_CHART=<path to the horizon chart> ./install_horizon_plugin.sh <horizon_plugin_image>
#   HORIZON_CHART=<path to the horizon chart> ./install_horizon_plugin.sh --rollback
#
# Example:
#   HORIZON_CHART=/opt/openstack-helm/horizon ./install_horizon_plugin.sh docker.io/trilio/trilio-horizon-plugin-helm:6.2.1-2026.1
#
# HORIZON_CHART must be the same chart version as the installed release (helm upgrade needs a
# chart, and the script refuses to change the chart version). The release keeps all its other
# values (--reuse-values); only images.tags.horizon changes.
#
# Use a new image tag for every rebuild: Horizon pulls with IfNotPresent, so a rebuilt image
# under an old tag never reaches nodes that already cached it.
#
# Optional environment variables:
#   RELEASE                 horizon Helm release name (default: horizon)
#   NAMESPACE               OpenStack namespace (default: openstack)
#   PULL_SECRET             T4O image pull secret (default: triliovault-image-registry)
#   PULL_SECRET_NAMESPACE   namespace of PULL_SECRET (default: trilio-openstack)
#   TIMEOUT                 seconds to wait for the Horizon rollout (default: 1800)

set -euo pipefail

RELEASE="${RELEASE:-horizon}"
NAMESPACE="${NAMESPACE:-openstack}"
PULL_SECRET="${PULL_SECRET:-triliovault-image-registry}"
PULL_SECRET_NAMESPACE="${PULL_SECRET_NAMESPACE:-trilio-openstack}"
TIMEOUT="${TIMEOUT:-1800}"
HORIZON_SA="horizon"
HORIZON_PULL_SECRET="trilio-horizon-image-registry"
PLUGIN_IMAGE_MATCH="trilio-horizon-plugin"

usage() {
    sed -n '/^# Usage:/,/^# Example:/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^Example:'
    exit 1
}

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

horizon_image() {
    kubectl -n "$NAMESPACE" get deploy horizon -o jsonpath='{.spec.template.spec.containers[?(@.name=="horizon")].image}'
}

release_status() {
    { helm -n "$NAMESPACE" status "$RELEASE" -o json 2>/dev/null || true; } \
        | grep -o '"status":"[a-z-]*"' | head -1 | cut -d'"' -f4
}

# Chart version of the installed release, from "helm list" (CHART column: <name>-<version>).
release_chart_version() {
    helm -n "$NAMESPACE" list --filter "^${RELEASE}\$" -o json \
        | grep -o '"chart":"[^"]*"' | cut -d'"' -f4 | sed "s/^horizon-//"
}

chart_path_version() {
    { helm show chart "$HORIZON_CHART" 2>/dev/null || true; } | awk '/^version:/ {print $2}'
}

# Names in the horizon ServiceAccount's imagePullSecrets, one per line.
sa_pull_secrets() {
    kubectl -n "$NAMESPACE" get sa "$HORIZON_SA" -o jsonpath='{range .imagePullSecrets[*]}{.name}{"\n"}{end}'
}

sa_has_our_secret() { sa_pull_secrets | grep -qx "$HORIZON_PULL_SECRET"; }

# Horizon container image deployed by a given release revision.
revision_image() {
    helm -n "$NAMESPACE" get manifest "$RELEASE" --revision "$1" 2>/dev/null \
        | awk '/^kind: Deployment/ {d=1} d && /image: / && /horizon/ {gsub(/"/,"",$2); print $2; exit}'
}

rollout_complete() {
    kubectl -n "$NAMESPACE" rollout status deploy/horizon --timeout=1s >/dev/null 2>&1
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
            echo "--- events of $bad:"
            kubectl -n "$NAMESPACE" get events --field-selector "involvedObject.name=$bad" \
                -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null | sort -u | tail -5 || true
            echo "--- last log lines of $bad:"
            kubectl -n "$NAMESPACE" logs "$bad" -c horizon --tail=25 2>/dev/null \
                || kubectl -n "$NAMESPACE" logs "$bad" -c horizon --previous --tail=25 2>/dev/null || true
        fi
        echo
        echo "The old Horizon pods keep serving until the new ones are Ready."
        echo "To go back to the stock Horizon image: HORIZON_CHART=$HORIZON_CHART $0 --rollback"
        exit 1
    fi
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
command -v helm >/dev/null 2>&1 || die "helm is not installed."
[[ -n "${HORIZON_CHART:-}" ]] || die "set HORIZON_CHART to the horizon chart the release was installed from (e.g. /opt/openstack-helm/horizon)."

[[ -n "$(release_status)" ]] || die "Helm release '$RELEASE' not found in '$NAMESPACE'."
INSTALLED_VERSION="$(release_chart_version)"
CHART_VERSION="$(chart_path_version)"
[[ -n "$CHART_VERSION" ]] || die "HORIZON_CHART='$HORIZON_CHART' is not a readable Helm chart."
[[ "$CHART_VERSION" == "$INSTALLED_VERSION" ]] \
    || die "HORIZON_CHART is version $CHART_VERSION but release '$RELEASE' runs $INSTALLED_VERSION; use the matching chart."
kubectl -n "$NAMESPACE" get sa "$HORIZON_SA" >/dev/null 2>&1 \
    || die "ServiceAccount '$HORIZON_SA' not found in '$NAMESPACE'."
log "Release: $NAMESPACE/$RELEASE (chart $INSTALLED_VERSION), current Horizon image: $(horizon_image)"

# Never upgrade while another Helm operation on the release is in progress.
[[ "$(release_status)" == "deployed" ]] \
    || die "release '$RELEASE' is '$(release_status)'; wait for the running Helm operation to finish."

# ---------------------------------------------------------------- rollback
if [[ "$ACTION" == "rollback" ]]; then
    if [[ "$(horizon_image)" != *"$PLUGIN_IMAGE_MATCH"* ]] && ! sa_has_our_secret; then
        log "Horizon does not run the Trilio plugin image; nothing to roll back."
        exit 0
    fi
    if [[ "$(horizon_image)" == *"$PLUGIN_IMAGE_MATCH"* ]]; then
        # Newest earlier revision whose Horizon image is not a Trilio plugin image.
        STOCK=""
        for rev in $(helm -n "$NAMESPACE" history "$RELEASE" --max 256 -o json \
                        | grep -o '"revision":[0-9]*' | cut -d: -f2 | sort -rn); do
            img="$(revision_image "$rev")"
            if [[ -n "$img" && "$img" != *"$PLUGIN_IMAGE_MATCH"* ]]; then STOCK="$img"; break; fi
        done
        [[ -n "$STOCK" ]] || die "no earlier revision of '$RELEASE' with a stock Horizon image; set it by hand with helm upgrade."
        log "helm upgrade $RELEASE (--reuse-values) with images.tags.horizon=$STOCK ..."
        helm -n "$NAMESPACE" upgrade "$RELEASE" "$HORIZON_CHART" --reuse-values \
            --set "images.tags.horizon=$STOCK" >/dev/null
        wait_for_horizon_rollout
    fi
    if sa_has_our_secret; then
        idx=$(sa_pull_secrets | grep -nx "$HORIZON_PULL_SECRET" | head -1 | cut -d: -f1)
        kubectl -n "$NAMESPACE" patch sa "$HORIZON_SA" --type json \
            -p "[{\"op\":\"remove\",\"path\":\"/imagePullSecrets/$((idx - 1))\"}]" >/dev/null
    fi
    kubectl -n "$NAMESPACE" delete secret "$HORIZON_PULL_SECRET" --ignore-not-found >/dev/null
    log "Rolled back. Horizon image: $(horizon_image)"
    exit 0
fi

# ---------------------------------------------------------------- install
kubectl -n "$PULL_SECRET_NAMESPACE" get secret "$PULL_SECRET" >/dev/null 2>&1 \
    || die "pull secret '$PULL_SECRET' not found in '$PULL_SECRET_NAMESPACE'; run ./create_image_pull_secret.sh first."

if [[ "$(horizon_image)" == "$IMG" ]] && rollout_complete && sa_has_our_secret; then
    log "Horizon already runs $IMG; nothing to do."
    exit 0
fi

# 1. Copy the registry credentials into the OpenStack namespace (pods can only use pull secrets
#    from their own namespace) and attach them to the horizon ServiceAccount.
log "Copying $PULL_SECRET_NAMESPACE/$PULL_SECRET to $NAMESPACE/$HORIZON_PULL_SECRET..."
kubectl -n "$PULL_SECRET_NAMESPACE" get secret "$PULL_SECRET" -o jsonpath='{.data.\.dockerconfigjson}' \
    | base64 -d \
    | kubectl -n "$NAMESPACE" create secret generic "$HORIZON_PULL_SECRET" \
        --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
        --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
if ! sa_has_our_secret; then
    log "Adding $HORIZON_PULL_SECRET to the imagePullSecrets of ServiceAccount $HORIZON_SA..."
    if [[ -z "$(sa_pull_secrets)" ]]; then
        kubectl -n "$NAMESPACE" patch sa "$HORIZON_SA" --type json \
            -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets\",\"value\":[{\"name\":\"$HORIZON_PULL_SECRET\"}]}]" >/dev/null
    else
        kubectl -n "$NAMESPACE" patch sa "$HORIZON_SA" --type json \
            -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets/-\",\"value\":{\"name\":\"$HORIZON_PULL_SECRET\"}}]" >/dev/null
    fi
fi

# 2. Point Horizon at the plugin image. Pods only pick up ServiceAccount pull secrets when they
#    are created, so if the image is already set (e.g. an earlier attempt without the secret),
#    restart the rollout instead.
if [[ "$(horizon_image)" == "$IMG" ]]; then
    log "deploy/horizon already uses $IMG; restarting it so the new pods get the pull secret..."
    kubectl -n "$NAMESPACE" rollout restart deploy/horizon >/dev/null
else
    log "helm upgrade $RELEASE (--reuse-values) with images.tags.horizon=$IMG ..."
    helm -n "$NAMESPACE" upgrade "$RELEASE" "$HORIZON_CHART" --reuse-values \
        --set "images.tags.horizon=$IMG" >/dev/null
    [[ "$(horizon_image)" == "$IMG" ]] || die "helm upgrade finished but deploy/horizon uses $(horizon_image)."
fi
wait_for_horizon_rollout

# 3. Verify the plugin is loaded in a running pod.
POD=$(kubectl -n "$NAMESPACE" get pods --no-headers | awk '/^horizon-/ && !/-db-/ && $2 == "1/1" {print $1; exit}')
ENABLED=$(kubectl -n "$NAMESPACE" exec "$POD" -c horizon -- sh -c \
    'ls /var/lib/openstack/lib/python3*/site-packages/openstack_dashboard/local/enabled/ \
        /var/lib/openstack/lib/python3*/site-packages/openstack_dashboard/enabled/ 2>/dev/null | grep -c "_tvault_"' || true)
log "Horizon pods:"
kubectl -n "$NAMESPACE" get pods -o wide | grep '^horizon-' | grep -v -- '-db-'
if [[ "${ENABLED:-0}" -gt 0 ]]; then
    log "Trilio Horizon plugin installed ($ENABLED panel files enabled in $POD)."
    echo "Log out of Horizon and back in to see the Backups tab."
else
    die "Horizon rolled out, but no Trilio panel files were found in $POD."
fi
