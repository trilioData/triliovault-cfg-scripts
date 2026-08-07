#!/usr/bin/env bash
#
# TVAULT-7556 - stamp Helm resource-ownership metadata on the Galera and RabbitMQ CRs.
#
# WHY THIS EXISTS
# ---------------
# Up to and including T4O 6.2.0, both the Galera CR and the RabbitMQ CR were templated as
# Helm *hooks*. Helm keeps hook resources out of the release manifest and never stamps
# them with ownership metadata (the app.kubernetes.io/managed-by label and the
# meta.helm.sh/release-name / release-namespace annotations).
#
# From 6.2.1 both CRs are plain templated resources, so that Helm patches them in place
# instead of deleting and recreating them on every upgrade (the RabbitMQ recreate minted a
# fresh default-user secret against reused PVCs and broke auth - TVAULT-7517; the Galera
# recreate tore the database down mid-upgrade and crash-looped the wlm/dmapi pods).
#
# Helm refuses to adopt a pre-existing object it never stamped:
#
#   failed to get candidate release: Unable to continue with update:
#   RabbitmqCluster "trilio-rabbitmq-cluster" ... cannot be imported into the current
#   release: invalid ownership metadata; label validation error: missing key
#   "app.kubernetes.io/managed-by": must be set to "Helm"; ...
#
# That aborts the upgrade *before* Helm builds a candidate release, so no hooks run and no
# Deployments are updated - the control plane silently stays on the old build.
#
# This script stamps the missing metadata (and drops the now-stale helm.sh/hook
# annotations) so Helm can adopt the existing objects.
#
# WHEN TO RUN IT
# --------------
# deploy_tvo_control_plane.sh runs it automatically, before applying
# tvo-operator-inputs.yaml. It is required for ANY upgrade coming from a release where
# these CRs were hooks - 6.1.x or 6.2.0 - regardless of which 6.2.x you are upgrading to
# (6.2.1, 6.2.2, ...). Running it directly is also supported.
#
# It is idempotent and safe to run repeatedly: objects that already carry the correct
# metadata are left untouched, and a fresh install where the CRs do not exist yet is a
# no-op.

set -euo pipefail

NAMESPACE="${TRILIO_NAMESPACE:-trilio-openstack}"

# Galera, plus both RabbitMQ CRD kinds - RHOSO switched from the upstream community
# RabbitMQ Cluster Operator to its own native operator at FR6/18.0.21 (TVAULT-7511), so a
# given cluster has one kind or the other. Anything not present is skipped.
#   <resource type>|<object name>
TARGETS=(
  "galeras.mariadb.openstack.org|trilio-galera-cluster"
  "rabbitmqclusters.rabbitmq.com|trilio-rabbitmq-cluster"
  "rabbitmqs.rabbitmq.openstack.org|trilio-rabbitmq-cluster"
)

MANAGED_BY_LABEL="app.kubernetes.io/managed-by"

# The Helm release name is the TVOControlPlane CR's name - the helm-operator names the
# release after the CR it reconciles - so derive it rather than hardcoding it (it has
# varied across releases, e.g. tvocontrolplane-v61).
resolve_release_name() {
  local names
  names="$(oc get tvocontrolplane -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

  if [ -z "$names" ]; then
    # Fresh install: the CR is applied later by deploy_tvo_control_plane.sh, and Helm will
    # create both cluster CRs itself with correct metadata. Nothing to adopt.
    return 1
  fi

  if [ "$(printf '%s\n' $names | wc -l)" -gt 1 ]; then
    echo "ERROR: found more than one TVOControlPlane CR in namespace '$NAMESPACE': $names" >&2
    echo "       Cannot determine which Helm release owns the Galera/RabbitMQ CRs." >&2
    echo "       Patch them manually, or remove the stale TVOControlPlane CR first." >&2
    exit 1
  fi

  printf '%s' "$names"
}

patch_target() {
  local resource="$1" name="$2" release="$3"
  local current_managed_by current_release current_ns current_hook

  if ! oc get "$resource" "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
    # CRD not registered on this cluster, or the object does not exist yet.
    return 0
  fi

  current_managed_by="$(oc get "$resource" "$name" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.labels.app\.kubernetes\.io/managed-by}" 2>/dev/null || true)"
  current_release="$(oc get "$resource" "$name" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.annotations.meta\.helm\.sh/release-name}" 2>/dev/null || true)"
  current_ns="$(oc get "$resource" "$name" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.annotations.meta\.helm\.sh/release-namespace}" 2>/dev/null || true)"
  current_hook="$(oc get "$resource" "$name" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.annotations.helm\.sh/hook}" 2>/dev/null || true)"

  if [ "$current_managed_by" = "Helm" ] && \
     [ "$current_release" = "$release" ] && \
     [ "$current_ns" = "$NAMESPACE" ] && \
     [ -z "$current_hook" ]; then
    echo "  $resource/$name: already owned by Helm release '$release' - no change"
    return 0
  fi

  echo "  $resource/$name: stamping Helm ownership metadata (release '$release')"

  # Setting the hook annotations to null removes them. They are leftovers from when this
  # CR was templated as a hook; Helm decides hook-ness from the rendered manifest, not from
  # the live object, so they are inert - but leaving them behind is misleading.
  oc patch "$resource" "$name" -n "$NAMESPACE" --type=merge -p "{
    \"metadata\": {
      \"labels\": {
        \"${MANAGED_BY_LABEL}\": \"Helm\"
      },
      \"annotations\": {
        \"meta.helm.sh/release-name\": \"${release}\",
        \"meta.helm.sh/release-namespace\": \"${NAMESPACE}\",
        \"helm.sh/hook\": null,
        \"helm.sh/hook-weight\": null
      }
    }
  }" >/dev/null

  echo "  $resource/$name: patched"
}

main() {
  if ! RELEASE_NAME="$(resolve_release_name)"; then
    echo "No TVOControlPlane CR in namespace '$NAMESPACE' - fresh install, nothing to adopt."
    return 0
  fi

  echo "Ensuring Galera/RabbitMQ CRs are owned by Helm release '$RELEASE_NAME' in '$NAMESPACE'..."
  for target in "${TARGETS[@]}"; do
    patch_target "${target%%|*}" "${target##*|}" "$RELEASE_NAME"
  done
  echo "Helm ownership metadata check complete."
}

main "$@"
