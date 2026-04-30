#!/bin/bash
# migrate_backup_targets_62.sh
#
# Migrates S3 backup target credentials from T4O 5.x (globals.yml plaintext)
# to OpenStack Barbican for T4O 6.2.
#
# What it does:
#   1. Reads each S3 backup target from workloadmgr
#   2. Prompts for S3 access/secret keys for each target (or reads from env)
#   3. Creates a Barbican secret payload using trilio-dms-cli
#   4. Stores the payload in Barbican
#   5. Resolves the public Barbican endpoint (openstack secret store returns
#      an internal http:// URL but workloadmgr requires the public https:// URL)
#   6. Updates the backup target record with the normalised Barbican secret href
#   7. Verifies the update was persisted correctly
#
# Prerequisites:
#   - T4O 6.2 is deployed and all containers are running
#   - WLM admin-openrc.sh is sourced (or pass --openrc <path>)
#   - trilio-dms-cli is installed in the WLM container or on the host
#   - workloadmgr CLI is installed
#
# Usage:
#   bash migrate_backup_targets_62.sh [--openrc /etc/kolla/admin-openrc.sh]
#
# For scripted/non-interactive use, export credentials before running:
#   export BT_S3_ACCESS_KEY_<BT_NAME_UPPERCASE>=<key>
#   export BT_S3_SECRET_KEY_<BT_NAME_UPPERCASE>=<key>
# (spaces and hyphens in backup target names are replaced with underscores)

set -e

OPENRC="/etc/kolla/admin-openrc.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }
die()      { echo "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --openrc) OPENRC="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------
# Source OpenRC
# -----------------------------------------------------------------------
[ -f "$OPENRC" ] || die "OpenRC file not found: $OPENRC. Use --openrc <path>."
# shellcheck disable=SC1090
source "$OPENRC"

log_step "T4O 5.x → 6.2 S3 Backup Target Credential Migration"

# -----------------------------------------------------------------------
# Get list of S3 backup targets from workloadmgr
# -----------------------------------------------------------------------
log "Fetching backup target list from workloadmgr..."
bt_json=$(workloadmgr backup-target-list --format json 2>/dev/null) \
  || die "Failed to list backup targets. Is workloadmgr installed and WLM running?"

s3_targets=$(echo "$bt_json" | python3 -c "
import json, sys
targets = json.load(sys.stdin)
for t in targets:
    if t.get('target_type', '').lower() in ('s3', 'amazon_s3', 'other_s3_compatible'):
        print(t['id'] + ' ' + t['name'])
" 2>/dev/null) || true

if [ -z "$s3_targets" ]; then
  log "No S3 backup targets found. Nothing to migrate."
  exit 0
fi

log "S3 backup targets to migrate:"
echo "$s3_targets" | while read -r bt_id bt_name; do
  log "  - $bt_name ($bt_id)"
done

# -----------------------------------------------------------------------
# Resolve public Barbican endpoint (needed to normalise secret href)
# -----------------------------------------------------------------------
log "Resolving public Barbican endpoint from keystone catalog..."
barbican_public=$(OS_INTERFACE=public openstack endpoint list \
    --service key-manager --interface public -f json 2>/dev/null \
  | python3 -c "
import json, sys
eps = json.load(sys.stdin)
if not eps:
    print('')
else:
    url = eps[0]['URL'].rstrip('/')
    # Remove /v1 suffix if present — we add it back with the secret UUID
    if url.endswith('/v1'):
        url = url[:-3]
    print(url)
" 2>/dev/null) || true

[ -n "$barbican_public" ] || die "Could not resolve public Barbican endpoint from keystone catalog."
log "Barbican public endpoint: $barbican_public"

# -----------------------------------------------------------------------
# Process each S3 backup target
# -----------------------------------------------------------------------
success=0
failed=0

while IFS=' ' read -r bt_id bt_name; do
  log_step "Processing: $bt_name ($bt_id)"

  # Derive env variable name from backup target name (uppercase, spaces/hyphens → underscores)
  env_key=$(echo "$bt_name" | tr '[:lower:]' '[:upper:]' | tr ' -' '__')

  # Get access key
  access_key_var="BT_S3_ACCESS_KEY_${env_key}"
  secret_key_var="BT_S3_SECRET_KEY_${env_key}"

  if [ -n "${!access_key_var}" ]; then
    access_key="${!access_key_var}"
    log "Access key: (from env $access_key_var)"
  else
    read -rsp "  S3 Access Key for '$bt_name': " access_key
    echo
  fi

  if [ -n "${!secret_key_var}" ]; then
    secret_key="${!secret_key_var}"
    log "Secret key: (from env $secret_key_var)"
  else
    read -rsp "  S3 Secret Key for '$bt_name': " secret_key
    echo
  fi

  # Get current backup target details for endpoint/bucket
  bt_details=$(workloadmgr backup-target-show "$bt_id" --format json 2>/dev/null) \
    || { log "ERROR: Could not fetch details for $bt_name. Skipping."; failed=$((failed+1)); continue; }

  bucket=$(echo "$bt_details" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('container',''))" 2>/dev/null)
  endpoint=$(echo "$bt_details" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('objectstore_endpoint',''))" 2>/dev/null)
  export_path=$(echo "$bt_details" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mount_path','TrilioVault'))" 2>/dev/null)

  # Create Barbican secret payload
  payload_file="$TMPDIR/secret_${bt_id}.json"
  log "Creating Barbican secret payload..."

  payload_args=(
    secret-payload create
    --access-key "$access_key"
    --secret-key "$secret_key"
    --bucket "$bucket"
    -o "$payload_file"
  )
  [ -n "$endpoint" ] && payload_args+=(--endpoint-url "$endpoint")
  [ -n "$export_path" ] && payload_args+=(--filesystem-export "$export_path")

  trilio-dms-cli "${payload_args[@]}" 2>/dev/null \
    || { log "ERROR: trilio-dms-cli failed for $bt_name. Skipping."; failed=$((failed+1)); continue; }

  # Store payload in Barbican
  secret_name="secret-key-${bt_name// /-}"
  log "Storing in Barbican as '$secret_name'..."
  secret_output=$(openstack secret store \
    --name "$secret_name" \
    --payload "$(cat "$payload_file")" \
    --format json 2>/dev/null) \
    || { log "ERROR: openstack secret store failed for $bt_name. Skipping."; failed=$((failed+1)); continue; }

  # Extract secret UUID and build normalised public href
  secret_uuid=$(echo "$secret_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
href = d.get('Secret href', '')
print(href.split('/')[-1])
" 2>/dev/null)

  [ -n "$secret_uuid" ] || { log "ERROR: Could not extract secret UUID for $bt_name. Skipping."; failed=$((failed+1)); continue; }

  normalised_href="${barbican_public}/v1/secrets/${secret_uuid}"
  log "Normalised secret href: $normalised_href"

  # Update backup target record
  log "Updating backup target record..."
  workloadmgr backup-target-modify --secret-ref "$normalised_href" "$bt_id" >/dev/null 2>&1 \
    || { log "ERROR: backup-target-modify failed for $bt_name. Skipping."; failed=$((failed+1)); continue; }

  # Verify secret_ref was persisted correctly
  stored_ref=$(workloadmgr backup-target-show "$bt_id" --format json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('secret_ref',''))" 2>/dev/null)

  if [ "$stored_ref" = "$normalised_href" ]; then
    log "OK: $bt_name — secret_ref verified."
    success=$((success+1))
  else
    log "WARNING: $bt_name — secret_ref mismatch after update."
    log "  Expected: $normalised_href"
    log "  Stored  : $stored_ref"
    failed=$((failed+1))
  fi

done <<< "$s3_targets"

log_step "Migration complete: $success succeeded, $failed failed"

if [ "$failed" -gt 0 ]; then
  log "Some backup targets failed. Check the output above and re-run for failed targets."
  exit 1
fi

log "All S3 backup targets migrated to Barbican successfully."
log "Verify with: workloadmgr backup-target-list"
