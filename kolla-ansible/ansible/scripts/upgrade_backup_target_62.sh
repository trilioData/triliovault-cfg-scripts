#!/bin/bash
# upgrade_backup_target_62.sh
#
# Creates the T4O 5.2 backup target in T4O 6.2 based on globals.yml.
# Use this after upgrading kolla-ansible from T4O 5.2 to T4O 6.2.
#
# In T4O 5.2 (kolla-ansible), a single backup target was configured via
# globals.yml variables. This script reads that config and creates it
# as the default backup target in T4O 6.2.
#
# For S3 targets: credentials are stored in OpenStack Barbican and the
# backup target is created with a reference to the Barbican secret.
# For NFS targets: created directly via workloadmgr.
#
# Prerequisites:
#   - T4O 6.2 is deployed and all containers are running
#   - T4O 5.2 cleanup is complete (cleanup_backup_targets.yml playbook has been run)
#   - python3 with PyYAML (pip3 install pyyaml)
#   - workloadmgr CLI (T4O 6.2)
#   - openstack CLI (for Barbican — S3 targets only)
#   - trilio-dms-cli (for building Barbican secret payload — S3 targets only)
#
# Usage:
#   bash upgrade_backup_target_62.sh \
#     [-g /etc/kolla/globals.yml] \
#     [--openrc /etc/kolla/admin-openrc.sh] \
#     [--name my-backup-target]
#
# For non-interactive use (S3), export the secret key before running:
#   export TRILIOVAULT_S3_SECRET_KEY=<secret>

set -e

GLOBALS="/etc/kolla/globals.yml"
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
    -g|--globals) GLOBALS="$2";  shift 2 ;;
    --openrc)     OPENRC="$2";   shift 2 ;;
    --name)       BT_NAME="$2";  shift 2 ;;
    *) die "Unknown argument: $1. Valid options: -g <globals.yml> --openrc <openrc> --name <bt-name>" ;;
  esac
done

# -----------------------------------------------------------------------
# Verify prerequisites
# -----------------------------------------------------------------------
[ -f "$GLOBALS" ] || die "globals.yml not found: $GLOBALS. Use -g <path>."
[ -f "$OPENRC"  ] || die "OpenRC file not found: $OPENRC. Use --openrc <path>."
python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML not available. Run: pip3 install pyyaml"
command -v workloadmgr >/dev/null 2>&1 || die "workloadmgr CLI not found. Ensure T4O 6.2 is running."

# shellcheck disable=SC1090
source "$OPENRC"

export _GLOBALS="$GLOBALS"

# -----------------------------------------------------------------------
# Read backup target config from globals.yml
# -----------------------------------------------------------------------
log_step "Reading backup target config from globals.yml ($GLOBALS)"

eval "$(python3 - <<'PYEOF'
import yaml, os, sys

with open(os.environ['_GLOBALS']) as f:
    d = yaml.safe_load(f) or {}

bt_type = d.get('triliovault_backup_target', '').strip()
if not bt_type:
    print("echo 'ERROR: triliovault_backup_target not set in globals.yml' >&2; exit 1")
    sys.exit(0)

def sh(v):
    return "'" + str(v).replace("'", "'\\''") + "'"

print("BT_TYPE=" + sh(bt_type))

if bt_type.lower() == 'nfs':
    print("NFS_SHARES=" + sh(d.get('triliovault_nfs_shares', '')))
    print("NFS_OPTIONS=" + sh(d.get('triliovault_nfs_options', '')))
    print("MULTI_IP_NFS=" + sh(d.get('multi_ip_nfs_enabled', 'no')))
elif bt_type.lower() in ('amazon_s3', 'other_s3_compatible'):
    print("S3_ACCESS_KEY=" + sh(d.get('triliovault_s3_access_key', '')))
    print("S3_BUCKET="     + sh(d.get('triliovault_s3_bucket_name', '')))
    print("S3_REGION="     + sh(d.get('triliovault_s3_region_name', 'us-east-1')))
    print("S3_ENDPOINT="   + sh(d.get('triliovault_s3_endpoint_url', '')))
    print("S3_VERSION="    + sh(d.get('triliovault_s3_version', 'default')))
    print("S3_AUTH_VER="   + sh(d.get('triliovault_s3_auth_version', 'DEFAULT')))
    print("S3_SSL="        + sh(d.get('triliovault_s3_ssl_enabled', False)))
    print("S3_SSL_VERIFY=" + sh(d.get('triliovault_s3_ssl_verify', True)))
    print("S3_CERT="       + sh(d.get('triliovault_s3_ssl_cert_file_name', '')))
else:
    print("echo 'ERROR: Unknown triliovault_backup_target value: " + bt_type + "' >&2; exit 1")
PYEOF
)"

log "Backup target type : $BT_TYPE"
log "Backup target name : $BT_NAME"

# -----------------------------------------------------------------------
# NFS backup target
# -----------------------------------------------------------------------
if [[ "$BT_TYPE" == "nfs" ]]; then
  log_step "Creating NFS backup target"
  [ -n "$NFS_SHARES" ] || die "triliovault_nfs_shares is empty in globals.yml."

  log "NFS shares         : $NFS_SHARES"
  log "NFS options        : $NFS_OPTIONS"
  log "Multi-IP NFS       : $MULTI_IP_NFS"

  workloadmgr backup-target-create \
    --name "$BT_NAME" \
    --type nfs \
    --nfs-shares "$NFS_SHARES" \
    --nfs-options "$NFS_OPTIONS" \
    --is-default true

  log "NFS backup target '$BT_NAME' created successfully."

# -----------------------------------------------------------------------
# S3 backup target
# -----------------------------------------------------------------------
elif [[ "$BT_TYPE" == "amazon_s3" || "$BT_TYPE" == "other_s3_compatible" ]]; then
  log_step "Creating S3 backup target"
  command -v openstack     >/dev/null 2>&1 || die "openstack CLI not found."
  command -v trilio-dms-cli >/dev/null 2>&1 || die "trilio-dms-cli not found."

  [ -n "$S3_ACCESS_KEY" ] || die "triliovault_s3_access_key is empty in globals.yml."
  [ -n "$S3_BUCKET"     ] || die "triliovault_s3_bucket_name is empty in globals.yml."

  log "S3 type        : $BT_TYPE"
  log "S3 access key  : $S3_ACCESS_KEY"
  log "S3 bucket      : $S3_BUCKET"
  log "S3 region      : $S3_REGION"
  log "S3 endpoint    : ${S3_ENDPOINT:-(default)}"
  log "S3 SSL enabled : $S3_SSL"

  # Get S3 secret key — from env or interactive prompt
  if [ -n "${TRILIOVAULT_S3_SECRET_KEY:-}" ]; then
    S3_SECRET_KEY="$TRILIOVAULT_S3_SECRET_KEY"
    log "S3 secret key  : (from env TRILIOVAULT_S3_SECRET_KEY)"
  else
    read -rsp "S3 Secret Key for $BT_NAME: " S3_SECRET_KEY
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

  # Build Barbican secret payload via trilio-dms-cli
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
  log "Barbican secret: $secret_href"

  # Create S3 backup target in T4O 6.2
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
log "Done. Backup target '$BT_NAME' is created and set as default."
log "Verify it is in 'available' status before triggering a backup."
