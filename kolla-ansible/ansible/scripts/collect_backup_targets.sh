#!/bin/bash
# collect_backup_targets.sh
#
# Reads T4O 5.2 backup target configuration from globals.yml and saves it
# to existing_backup_targets.yaml BEFORE upgrading to T4O 6.2.
#
# This file is used as input for create_backup_target_62.yml after the upgrade.
# It must be run before the upgrade because cleanup_backup_targets.yml removes
# backup target variables from globals.yml as part of the upgrade cleanup.
#
# In T4O 5.2 (kolla-ansible), only a single backup target is supported,
# configured via globals.yml variables.
#
# No workloadmgr CLI calls are made — T4O 5.2 did not support backup-target-list/show.
#
# Prerequisites:
#   - python3 with PyYAML (pip3 install pyyaml)
#
# Usage:
#   bash collect_backup_targets.sh \
#     [-g /etc/kolla/globals.yml] \
#     [-o existing_backup_targets.yaml]
#
# Output:
#   existing_backup_targets.yaml  (path overridable with -o)

set -e

GLOBALS="/etc/kolla/globals.yml"
OUTPUT="existing_backup_targets.yaml"

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }
die()      { echo "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--globals) GLOBALS="$2"; shift 2 ;;
    -o|--output)  OUTPUT="$2";  shift 2 ;;
    *) die "Unknown argument: $1. Valid options: -g <globals.yml> -o <output.yaml>" ;;
  esac
done

[ -f "$GLOBALS" ] || die "globals.yml not found: $GLOBALS. Use -g <path>."
python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML not available. Run: pip3 install pyyaml"

export _GLOBALS="$GLOBALS"
export _OUTPUT="$OUTPUT"

log_step "Reading backup target config from $GLOBALS"

python3 - <<'PYEOF'
import yaml, os, sys
from datetime import datetime

globals_path = os.environ['_GLOBALS']
output_path  = os.environ['_OUTPUT']

with open(globals_path) as f:
    d = yaml.safe_load(f) or {}

bt_type = d.get('triliovault_backup_target', '').strip()

if not bt_type:
    print("  ERROR: triliovault_backup_target not found in " + globals_path)
    sys.exit(1)

print("  Backup target type : " + bt_type)

config = {'type': bt_type}

if bt_type.lower() == 'nfs':
    config['nfs_shares']       = d.get('triliovault_nfs_shares', '')
    config['nfs_options']      = d.get('triliovault_nfs_options', '')
    config['multi_ip_nfs_enabled'] = d.get('multi_ip_nfs_enabled', 'no')
    print("  NFS shares         : " + str(config['nfs_shares']))
    print("  NFS options        : " + str(config['nfs_options']))
    print("  Multi-IP NFS       : " + str(config['multi_ip_nfs_enabled']))

elif bt_type.lower() in ('amazon_s3', 'other_s3_compatible'):
    config['s3_access_key']          = d.get('triliovault_s3_access_key', '')
    config['s3_secret_key']          = d.get('triliovault_s3_secret_key', '')
    config['s3_bucket']              = d.get('triliovault_s3_bucket_name', '')
    config['s3_region']              = d.get('triliovault_s3_region_name', 'us-east-1')
    config['s3_endpoint']            = d.get('triliovault_s3_endpoint_url', '')
    config['s3_version']             = d.get('triliovault_s3_version', 'default')
    config['s3_auth_version']        = d.get('triliovault_s3_auth_version', 'DEFAULT')
    config['s3_ssl_enabled']         = d.get('triliovault_s3_ssl_enabled', False)
    config['s3_ssl_verify']          = d.get('triliovault_s3_ssl_verify', True)
    config['s3_ssl_cert_file_name']  = d.get('triliovault_s3_ssl_cert_file_name', '')
    config['copy_ceph_s3_ssl_cert']  = d.get('triliovault_copy_ceph_s3_ssl_cert', False)
    print("  S3 access key      : " + str(config['s3_access_key']))
    print("  S3 secret key      : " + ("(set)" if config['s3_secret_key'] else "(empty)"))
    print("  S3 bucket          : " + str(config['s3_bucket']))
    print("  S3 region          : " + str(config['s3_region']))
    print("  S3 endpoint        : " + str(config['s3_endpoint'] or '(default)'))
    print("  S3 SSL enabled     : " + str(config['s3_ssl_enabled']))

else:
    print("  ERROR: Unknown triliovault_backup_target value: " + bt_type)
    sys.exit(1)

output = {
    '_collected_at':  datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    '_source_globals': globals_path,
    'backup_target':   config,
}

with open(output_path, 'w') as f:
    f.write("# T4O 5.2 Backup Target Configuration\n")
    f.write("# Collected before upgrade to T4O 6.2\n")
    f.write("#\n")
    yaml.dump(output, f, default_flow_style=False, allow_unicode=True)

print("  Written: " + output_path)
PYEOF

log ""
log "Done. Review $OUTPUT before proceeding with the upgrade."
log ""
log "Next steps:"
log "  1. Upgrade to T4O 6.2:  kolla-ansible upgrade --tags triliovault"
log "  2. Run cleanup:          ansible-playbook cleanup_backup_targets.yml --tags upgrade-and-clean-backup-target-mounts"
log "  3. Re-create BT:         ansible-playbook -i <INVENTORY> create_backup_target_62.yml"
