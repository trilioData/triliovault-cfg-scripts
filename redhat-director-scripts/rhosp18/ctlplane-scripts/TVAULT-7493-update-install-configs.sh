#!/bin/bash
# TVAULT-7493: patch the install-script config files (not the Helm chart) to
# match the renamed Galera CR (trilio-galera-cluster -> trilio-db-cluster).
#
# Scope: redhat-director-scripts/rhosp18/ctlplane-scripts/ top-level install
# files only -- tvo-operator-inputs.yaml and certificate.yaml. Does NOT touch
# anything under operator/tvo-operator/helm-charts/ (already fixed at source
# and shipped via the operator image itself), and does not apply anything to
# a cluster -- run update_galera_cert_dns.sh / install_operator.sh for that.
#
# Idempotent: safe to re-run against files that are already updated (no-op).
set -euo pipefail

OLD_HOST="trilio-galera-cluster.trilio-openstack.svc"
NEW_HOST="trilio-db-cluster.trilio-openstack.svc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

patch_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: $file not found, skipping." >&2
    return
  fi

  if ! grep -q "$OLD_HOST" "$file"; then
    if grep -q "$NEW_HOST" "$file"; then
      echo "OK: $file already up to date, nothing to do."
    else
      echo "WARNING: $file contains neither the old nor the new hostname -- check manually." >&2
    fi
    return
  fi

  echo "==> Patching $file ($OLD_HOST -> $NEW_HOST)"
  echo "    Before:"
  grep -n "$OLD_HOST" "$file" | sed 's/^/      /'
  sed -i "s/${OLD_HOST}/${NEW_HOST}/g" "$file"
  echo "    After:"
  grep -n "$NEW_HOST" "$file" | sed 's/^/      /'

  if grep -q "$OLD_HOST" "$file"; then
    echo "ERROR: $file still contains $OLD_HOST after patching -- check manually." >&2
    exit 1
  fi
}

echo "==> TVAULT-7493: updating install-script configs (not the Helm chart)"
echo ""
patch_file "tvo-operator-inputs.yaml"
echo ""
patch_file "certificate.yaml"

echo ""
echo "==> Done. Files under operator/tvo-operator/helm-charts/ were not touched -- that fix ships via the operator image."
echo "==> Next: oc apply the updated tvo-operator-inputs.yaml, then run ./update_galera_cert_dns.sh (see TVAULT-7493 runbook)."
