#!/usr/bin/env bash
## This script is just one time fix to old tvobackuptarget CRs deployed using T4O 6.1.3 or older operator versions.
## This script is not needed if your tvobackuptarget CRs deployed with T4O 6.1.4 operator or newer versions.
## Once you execute the script, it patches allinstances of tvobackuptarget CRs in trilio-openstack namespace with necessary helm annotations
## and labels so that upgrade of these CRs happens properly by helm operator
set -euo pipefail

NAMESPACE="trilio-openstack"

# Get all TVOBackupTarget CRs in the namespace
CRS=$(oc get tvobackuptarget -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')

for CR in $CRS; do
  echo "Processing CR: $CR"

  # Extract the backup target name (strip the leading 'tvobackuptarget-')
  BT_NAME=${CR#tvobackuptarget-}

  # Build the corresponding DaemonSet name
  DS_NAME="triliovault-object-store-${BT_NAME}"

  echo "  -> Patching DaemonSet: $DS_NAME with release name: $CR"

  oc patch ds "$DS_NAME" -n "$NAMESPACE" \
    --type=merge -p "{
      \"metadata\": {
        \"labels\": {
          \"app.kubernetes.io/managed-by\": \"Helm\"
        },
        \"annotations\": {
          \"meta.helm.sh/release-name\": \"${CR}\",
          \"meta.helm.sh/release-namespace\": \"${NAMESPACE}\"
        }
      }
    }" || echo "  !! Failed to patch $DS_NAME (might not exist)"
done
