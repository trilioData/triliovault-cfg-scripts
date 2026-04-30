#!/bin/bash
# collect_backup_targets.sh
#
# Collects existing T4O 5.x backup target configuration BEFORE upgrading to T4O 6.2.
# Reads all backup target variables from globals.yml and cross-checks with the
# running workloadmgr API. Writes a combined inventory YAML file used as a
# reference during migration with migrate_backup_targets_62.sh.
#
# Run this BEFORE starting the upgrade to T4O 6.2.
#
# Prerequisites:
#   - T4O 5.x is still running
#   - workloadmgr CLI is installed and accessible
#   - python3 with PyYAML (pip3 install pyyaml)
#
# Usage:
#   bash collect_backup_targets.sh \
#     [-g /etc/kolla/globals.yml] \
#     [--openrc /etc/kolla/admin-openrc.sh] \
#     [-o existing_backup_targets.yaml]
#
# Output:
#   existing_backup_targets.yaml  (path overridable with -o)
#
# NOTE: S3 secret keys (triliovault_s3_secret_key) are NOT written to the output
# file for security. You will be prompted for them during migrate_backup_targets_62.sh.

set -e

GLOBALS="/etc/kolla/globals.yml"
OPENRC="/etc/kolla/admin-openrc.sh"
OUTPUT="existing_backup_targets.yaml"

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
    -o|--output)  OUTPUT="$2";   shift 2 ;;
    *) die "Unknown argument: $1. Valid options: -g <globals.yml> --openrc <openrc> -o <output.yaml>" ;;
  esac
done

# -----------------------------------------------------------------------
# Verify prerequisites
# -----------------------------------------------------------------------
[ -f "$GLOBALS" ] || die "globals.yml not found: $GLOBALS. Use -g <path>."
[ -f "$OPENRC" ]  || die "OpenRC file not found: $OPENRC. Use --openrc <path>."
python3 -c "import yaml" 2>/dev/null \
  || die "python3 PyYAML not available. Run: pip3 install pyyaml"
command -v workloadmgr >/dev/null 2>&1 \
  || die "workloadmgr CLI not found. Ensure T4O 5.x is running and workloadmgr is on PATH."

# shellcheck disable=SC1090
source "$OPENRC"

# -----------------------------------------------------------------------
# Step 1: Extract backup target config from globals.yml
# -----------------------------------------------------------------------
log_step "Step 1: Reading backup target config from globals.yml ($GLOBALS)"

export _GLOBALS="$GLOBALS"

python3 - <<'PYEOF'
import yaml, os, sys

with open(os.environ['_GLOBALS']) as f:
    d = yaml.safe_load(f) or {}

bt_type = d.get('triliovault_backup_target', '').strip()

if not bt_type:
    print("  triliovault_backup_target : (not set)")
    print("  Backup target may have been configured via workloadmgr CLI only.")
    sys.exit(0)

print("  Backup target type        : " + bt_type)

if bt_type.lower() == 'nfs':
    print("  NFS shares                : " + str(d.get('triliovault_nfs_shares', '(not set)')))
    print("  NFS options               : " + str(d.get('triliovault_nfs_options', '(not set)')))
    print("  multi_ip_nfs_enabled      : " + str(d.get('multi_ip_nfs_enabled', 'no')))
elif bt_type.lower() in ('amazon_s3', 'other_s3_compatible'):
    print("  S3 access key             : " + str(d.get('triliovault_s3_access_key', '(not set)')))
    print("  S3 secret key             : *** REDACTED ***")
    print("  S3 bucket                 : " + str(d.get('triliovault_s3_bucket_name', '(not set)')))
    print("  S3 region                 : " + str(d.get('triliovault_s3_region_name', '(not set)')))
    print("  S3 endpoint               : " + str(d.get('triliovault_s3_endpoint_url', '(not set)')))
    print("  S3 version                : " + str(d.get('triliovault_s3_version', 'default')))
    print("  S3 auth version           : " + str(d.get('triliovault_s3_auth_version', 'DEFAULT')))
    print("  S3 SSL enabled            : " + str(d.get('triliovault_s3_ssl_enabled', False)))
    print("  S3 SSL verify             : " + str(d.get('triliovault_s3_ssl_verify', True)))
    print("  S3 SSL cert file          : " + str(d.get('triliovault_s3_ssl_cert_file_name', '(not set)')))
    print("  copy_ceph_s3_ssl_cert     : " + str(d.get('triliovault_copy_ceph_s3_ssl_cert', False)))
PYEOF

# -----------------------------------------------------------------------
# Step 2: Fetch backup targets from workloadmgr
# -----------------------------------------------------------------------
log_step "Step 2: Fetching backup target list from workloadmgr API"

bt_json=$(workloadmgr backup-target-list --format json 2>/dev/null) \
  || die "workloadmgr backup-target-list failed. Is T4O running?"

bt_count=$(echo "$bt_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
log "Found $bt_count backup target(s) in workloadmgr:"

echo "$bt_json" | python3 -c "
import json, sys
for t in json.load(sys.stdin):
    print('  [{status}] {name} ({id}) — type: {type}'.format(
        status=t.get('status','?'),
        name=t.get('name','?'),
        id=t.get('id','?'),
        type=t.get('target_type','?'),
    ))
" 2>/dev/null

# -----------------------------------------------------------------------
# Step 3: Write output file
# -----------------------------------------------------------------------
log_step "Step 3: Writing inventory file -> $OUTPUT"

export _BT_JSON="$bt_json"
export _OUTPUT="$OUTPUT"

python3 - <<'PYEOF'
import yaml, json, os
from datetime import datetime

globals_path = os.environ['_GLOBALS']
bt_json_str  = os.environ['_BT_JSON']
output_path  = os.environ['_OUTPUT']

with open(globals_path) as f:
    d = yaml.safe_load(f) or {}

bt_type = d.get('triliovault_backup_target', '').strip()

globals_config = {}
if bt_type:
    globals_config['triliovault_backup_target'] = bt_type

    if bt_type.lower() == 'nfs':
        globals_config['triliovault_nfs_shares']  = d.get('triliovault_nfs_shares', '')
        globals_config['triliovault_nfs_options'] = d.get('triliovault_nfs_options', '')
        globals_config['multi_ip_nfs_enabled']    = d.get('multi_ip_nfs_enabled', 'no')

    elif bt_type.lower() in ('amazon_s3', 'other_s3_compatible'):
        globals_config['triliovault_s3_access_key']      = d.get('triliovault_s3_access_key', '')
        globals_config['triliovault_s3_secret_key']      = '*** REDACTED — enter manually during migration ***'
        globals_config['triliovault_s3_bucket_name']     = d.get('triliovault_s3_bucket_name', '')
        globals_config['triliovault_s3_region_name']     = d.get('triliovault_s3_region_name', 'us-east-1')
        globals_config['triliovault_s3_endpoint_url']    = d.get('triliovault_s3_endpoint_url', '')
        globals_config['triliovault_s3_version']         = d.get('triliovault_s3_version', 'default')
        globals_config['triliovault_s3_auth_version']    = d.get('triliovault_s3_auth_version', 'DEFAULT')
        globals_config['triliovault_s3_ssl_enabled']     = d.get('triliovault_s3_ssl_enabled', False)
        globals_config['triliovault_s3_ssl_verify']      = d.get('triliovault_s3_ssl_verify', True)
        globals_config['triliovault_s3_ssl_cert_file_name'] = d.get('triliovault_s3_ssl_cert_file_name', '')
        globals_config['triliovault_copy_ceph_s3_ssl_cert'] = d.get('triliovault_copy_ceph_s3_ssl_cert', False)

wlm_targets = []
for t in json.loads(bt_json_str):
    wlm_targets.append({
        'id':                   t.get('id', ''),
        'name':                 t.get('name', ''),
        'type':                 t.get('target_type', ''),
        'status':               t.get('status', ''),
        'mount_path':           t.get('mount_path', ''),
        'objectstore_endpoint': t.get('objectstore_endpoint', ''),
        'container':            t.get('container', ''),
    })

output = {
    '_collected_at':  datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    '_source_globals': globals_path,
    'globals_config':  globals_config if globals_config else None,
    'workloadmgr_backup_targets': wlm_targets,
}

with open(output_path, 'w') as f:
    f.write("# T4O 5.x Backup Target Inventory\n")
    f.write("# Collected before upgrade to T4O 6.2\n")
    f.write("#\n")
    f.write("# IMPORTANT:\n")
    f.write("#   - Review all values before proceeding with the upgrade.\n")
    f.write("#   - S3 secret keys are REDACTED here. Note them down separately.\n")
    f.write("#   - Pass this file to migrate_backup_targets_62.sh after T4O 6.2 is deployed.\n")
    f.write("#\n")
    yaml.dump(output, f, default_flow_style=False, allow_unicode=True)

print("Written: " + output_path)
PYEOF

# -----------------------------------------------------------------------
# Step 4: Cross-check count and warn on mismatch
# -----------------------------------------------------------------------
log_step "Step 4: Verification"

globals_has_bt=$(python3 -c "
import yaml, os
with open(os.environ['_GLOBALS']) as f:
    d = yaml.safe_load(f) or {}
print('1' if d.get('triliovault_backup_target','').strip() else '0')
" 2>/dev/null)

log "Backup target in globals.yml  : $([ "$globals_has_bt" = "1" ] && echo 'yes' || echo 'no')"
log "Backup targets in workloadmgr : $bt_count"

if [ "$globals_has_bt" = "1" ] && [ "$bt_count" -eq 0 ]; then
  log "WARNING: globals.yml has a backup target configured but workloadmgr lists none."
  log "         T4O may not be fully running. Verify before proceeding with upgrade."
elif [ "$globals_has_bt" = "0" ] && [ "$bt_count" -gt 0 ]; then
  log "NOTE: No backup target in globals.yml but workloadmgr lists $bt_count target(s)."
  log "      These were added dynamically via CLI/API. All are captured in $OUTPUT."
elif [ "$bt_count" -gt 1 ]; then
  log "NOTE: Multiple backup targets found in workloadmgr. All are captured in $OUTPUT."
fi

log ""
log "Output file : $OUTPUT"
log ""
log "Next steps:"
log "  1. Open and review $OUTPUT — verify all values."
log "  2. Note down S3 secret key(s) separately — NOT stored in output file."
log "  3. Proceed with T4O 6.2 upgrade (kolla-ansible upgrade --tags triliovault)."
log "  4. Run cleanup: ansible-playbook cleanup_backup_targets.yml --tags upgrade-and-clean-backup-target-mounts"
log "  5. Re-add backup targets: bash migrate_backup_targets_62.sh"
