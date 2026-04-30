#!/bin/bash
# upgrade_backup_target_62.sh
#
# Creates the T4O 5.2 backup target in T4O 6.2.
# Use this after upgrading kolla-ansible from T4O 5.2 to T4O 6.2 and after
# running the cleanup playbook (cleanup_backup_targets.yml).
#
# Reads backup target config from existing_backup_targets.yaml produced by
# collect_backup_targets.sh (run that script BEFORE the upgrade).
#
# For S3 targets: credentials are stored in OpenStack Barbican and the
# backup target is created with a Barbican secret reference.
# For NFS targets: created directly via workloadmgr.
# The backup target is set as default.
#
# Prerequisites:
#   - existing_backup_targets.yaml produced by collect_backup_targets.sh
#   - T4O 6.2 is deployed and all containers are running
#   - python3 with PyYAML (pip3 install pyyaml)
#   - workloadmgr CLI (T4O 6.2)
#   - openstack CLI (Barbican — S3 targets only)
#   - trilio-dms-cli (S3 targets only)
#
# Usage:
#   bash upgrade_backup_target_62.sh \
#     [-f existing_backup_targets.yaml] \
#     [--openrc /etc/kolla/admin-openrc.sh] \
#     [--name my-backup-target]
#
# For non-interactive S3 migration, export the secret key before running:
#   export TRILIOVAULT_S3_SECRET_KEY=<secret>

set -e

COLLECTED_FILE="existing_backup_targets.yaml"
OPENRC="/etc/kolla/admin-openrc.sh"
BT_NAME="default-backup-target"
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
    -f|--file)  COLLECTED_FILE="$2"; shift 2 ;;
    --openrc)   OPENRC="$2";         shift 2 ;;
    --name)     BT_NAME="$2";        shift 2 ;;
    *) die "Unknown argument: $1. Valid options: -f <collected.yaml> --openrc <openrc> --name <bt-name>" ;;
  esac
done

# -----------------------------------------------------------------------
# Verify prerequisites
# -----------------------------------------------------------------------
[ -f "$COLLECTED_FILE" ] || die "Collected file not found: $COLLECTED_FILE. Run collect_backup_targets.sh first."
[ -f "$OPENRC"         ] || die "OpenRC file not found: $OPENRC. Use --openrc <path>."
python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML not available. Run: pip3 install pyyaml"
command -v workloadmgr >/dev/null 2>&1 || die "workloadmgr CLI not found. Ensure T4O 6.2 is running."

# shellcheck disable=SC1090
source "$OPENRC"

export _COLLECTED_FILE="$COLLECTED_FILE"

# -----------------------------------------------------------------------
# Read backup target config from collected file
# -----------------------------------------------------------------------
log_step "Reading backup target config from $COLLECTED_FILE"

eval "$(python3 - <<'PYEOF'
import yaml, os, sys

with open(os.environ['_COLLECTED_FILE']) as f:
    d = yaml.safe_load(f) or {}

bt = d.get('backup_target', {})
bt_type = bt.get('type', '').strip()

if not bt_type:
    print("echo 'ERROR: backup_target.type not found in collected file' >&2; exit 1")
    sys.exit(0)

def sh(v):
    return "'" + str(v).replace("'", "'\\''") + "'"

print("BT_TYPE=" + sh(bt_type))

if bt_type.lower() == 'nfs':
    print("NFS_SHARES="  + sh(bt.get('nfs_shares', '')))
    print("NFS_OPTIONS=" + sh(bt.get('nfs_options', '')))
    print("MULTI_IP_NFS="+ sh(bt.get('multi_ip_nfs_enabled', 'no')))
elif bt_type.lower() in ('amazon_s3', 'other_s3_compatible'):
    print("S3_ACCESS_KEY=" + sh(bt.get('s3_access_key', '')))
    print("S3_BUCKET="     + sh(bt.get('s3_bucket', '')))
    print("S3_REGION="     + sh(bt.get('s3_region', 'us-east-1')))
    print("S3_ENDPOINT="   + sh(bt.get('s3_endpoint', '')))
    print("S3_VERSION="    + sh(bt.get('s3_version', 'default')))
    print("S3_AUTH_VER="   + sh(bt.get('s3_auth_version', 'DEFAULT')))
    print("S3_SSL="        + sh(bt.get('s3_ssl_enabled', False)))
    print("S3_SSL_VERIFY=" + sh(bt.get('s3_ssl_verify', True)))
    print("S3_CERT="       + sh(bt.get('s3_ssl_cert_file_name', '')))
else:
    print("echo 'ERROR: Unknown backup target type: " + bt_type + "' >&2; exit 1")
PYEOF
)"

log "Backup target type : $BT_TYPE"
log "Backup target name : $BT_NAME"

# -----------------------------------------------------------------------
# NFS backup target
# -----------------------------------------------------------------------
if [[ "$BT_TYPE" == "nfs" ]]; then
  log_step "Creating NFS backup target"
  [ -n "$NFS_SHARES" ] || die "nfs_shares is empty in $COLLECTED_FILE."

  log "NFS shares   : $NFS_SHARES"
  log "NFS options  : $NFS_OPTIONS"
  log "Multi-IP NFS : $MULTI_IP_NFS"

  workloadmgr backup-target-create \
    --name       "$BT_NAME" \
    --type       nfs \
    --nfs-shares "$NFS_SHARES" \
    --nfs-options "$NFS_OPTIONS" \
    --is-default true

  log "NFS backup target '$BT_NAME' created successfully."

# -----------------------------------------------------------------------
# S3 backup target
# -----------------------------------------------------------------------
elif [[ "$BT_TYPE" == "amazon_s3" || "$BT_TYPE" == "other_s3_compatible" ]]; then
  log_step "Creating S3 backup target"
  command -v openstack      >/dev/null 2>&1 || die "openstack CLI not found."
  command -v trilio-dms-cli >/dev/null 2>&1 || die "trilio-dms-cli not found."

  [ -n "$S3_ACCESS_KEY" ] || die "s3_access_key is empty in $COLLECTED_FILE."
  [ -n "$S3_BUCKET"     ] || die "s3_bucket is empty in $COLLECTED_FILE."

  log "S3 type       : $BT_TYPE"
  log "S3 access key : $S3_ACCESS_KEY"
  log "S3 bucket     : $S3_BUCKET"
  log "S3 region     : $S3_REGION"
  log "S3 endpoint   : ${S3_ENDPOINT:-(default)}"
  log "S3 SSL        : $S3_SSL"

  # Get S3 secret key — from env or interactive prompt
  if [ -n "${TRILIOVAULT_S3_SECRET_KEY:-}" ]; then
    S3_SECRET_KEY="$TRILIOVAULT_S3_SECRET_KEY"
    log "S3 secret key : (from env TRILIOVAULT_S3_SECRET_KEY)"
  else
    read -rsp "Enter S3 Secret Key (triliovault_s3_secret_key from T4O 5.2 globals.yml): " S3_SECRET_KEY
    echo
    [ -n "$S3_SECRET_KEY" ] || die "S3 secret key cannot be empty."
  fi

  # Resolve public Barbican endpoint
  log_step "Resolving public Barbican endpoint"
  barbican_public=$(OS_INTERFACE=public openstack endpoint list \
      --service key-manager --interface public -f json 2>/dev/null \
    | python3 -c "
import json, sys
eps = json.load(sys.stdin)
if not eps: print(''); sys.exit(0)
url = eps[0]['URL'].rstrip('/')
if url.endswith('/v1'): url = url[:-3]
print(url)
" 2>/dev/null) || true
  [ -n "$barbican_public" ] || die "Could not resolve public Barbican endpoint from keystone catalog."
  log "Barbican public endpoint: $barbican_public"

  # Build Barbican secret payload
  log_step "Building Barbican secret payload"
  payload_file="$TMPDIR/secret_payload.json"
  payload_args=(
    secret-payload create
    --access-key "$S3_ACCESS_KEY"
    --secret-key "$S3_SECRET_KEY"
    --bucket     "$S3_BUCKET"
    -o           "$payload_file"
  )
  [ -n "$S3_ENDPOINT" ] && payload_args+=(--endpoint-url "$S3_ENDPOINT")

  trilio-dms-cli "${payload_args[@]}" 2>/dev/null \
    || die "trilio-dms-cli secret-payload create failed."

  # Store in Barbican
  log_step "Storing credentials in Barbican"
  secret_name="secret-key-${BT_NAME// /-}"
  secret_output=$(openstack secret store \
    --name "$secret_name" \
    --payload "$(cat "$payload_file")" \
    --format json 2>/dev/null) \
    || die "openstack secret store failed."

  secret_uuid=$(echo "$secret_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('Secret href', '').split('/')[-1])
" 2>/dev/null)
  [ -n "$secret_uuid" ] || die "Could not extract Barbican secret UUID."

  secret_href="${barbican_public}/v1/secrets/${secret_uuid}"
  log "Barbican secret href: $secret_href"

  # Create backup target in T4O 6.2
  log_step "Creating S3 backup target in T4O 6.2"
  workloadmgr backup-target-create \
    --name       "$BT_NAME" \
    --type       "$BT_TYPE" \
    --secret-ref "$secret_href" \
    --is-default true

  log "S3 backup target '$BT_NAME' created successfully."
fi

# -----------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------
log_step "Verification"
workloadmgr backup-target-list
log ""
log "Done. '$BT_NAME' created and set as default."
log "Verify it shows 'available' status before triggering a backup."
