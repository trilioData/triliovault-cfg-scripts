#!/bin/bash
# collect_backup_targets.sh
#
# Reads T4O 5.x/6.0/6.1 backup target configuration from the Juju charm config
# and saves it to existing_backup_targets.json BEFORE upgrading to T4O 6.2.
#
# This file is used as input for recreate_backup_targets.sh after the upgrade.
# It must be run before the upgrade because the trilio-backup-targets config option
# is removed in 6.2 charms.
#
# The trilio-backup-targets option stores a JSON array on trilio-wlm (and optionally
# trilio-data-mover). This script reads the JSON, redacts S3 secret keys, and saves
# it to a file.
#
# Prerequisites:
#   - juju CLI authenticated and connected to the OpenStack model
#   - python3
#
# Usage:
#   bash collect_backup_targets.sh \
#     [-a trilio-wlm] \
#     [-o existing_backup_targets.json]
#
# Output:
#   existing_backup_targets.json  (path overridable with -o)
#
# NOTE: S3 secret keys in charm config are often empty (operators entered them
#       interactively). You will be prompted for any missing secret keys when
#       running recreate_backup_targets.sh.

set -e

APP="trilio-wlm"
OUTPUT="existing_backup_targets.json"

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }
die()      { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--app)    APP="$2";    shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    *) die "Unknown argument: $1. Valid options: -a <juju-app> -o <output.json>" ;;
  esac
done

command -v juju   >/dev/null 2>&1 || die "juju CLI not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."

log_step "Reading backup target config from Juju charm: $APP"

BT_JSON=$(juju config "$APP" trilio-backup-targets 2>/dev/null || echo "")

if [ -z "$BT_JSON" ] || [ "$BT_JSON" = "null" ] || [ "$BT_JSON" = "[]" ]; then
    log "No backup targets found on $APP. Trying trilio-data-mover..."
    BT_JSON=$(juju config trilio-data-mover trilio-backup-targets 2>/dev/null || echo "")
fi

if [ -z "$BT_JSON" ] || [ "$BT_JSON" = "null" ] || [ "$BT_JSON" = "[]" ]; then
    log "WARNING: No backup targets found in Juju charm config."
    log "This may mean backup targets were never configured, or the charm is already on 6.2."
    echo "[]" > "$OUTPUT"
    log "Written empty list to: $OUTPUT"
    exit 0
fi

export _BT_JSON="$BT_JSON"
export _OUTPUT="$OUTPUT"

python3 - <<'PYEOF'
import json, os, sys
from datetime import datetime

bt_json = os.environ['_BT_JSON']
output_path = os.environ['_OUTPUT']

try:
    targets = json.loads(bt_json)
except json.JSONDecodeError as e:
    print("ERROR: Failed to parse trilio-backup-targets JSON: " + str(e), file=sys.stderr)
    sys.exit(1)

if not isinstance(targets, list):
    targets = [targets]

print("  Found {} backup target(s):".format(len(targets)))
for i, t in enumerate(targets):
    name = t.get('backup-target-name', 'unnamed')
    btype = t.get('backup-target-type', 'unknown')
    is_default = t.get('is-default', False)
    print("  [{}] {} (type: {}, default: {})".format(i+1, name, btype, is_default))

    # Redact S3 secret keys
    if 's3-secret-key' in t:
        if t['s3-secret-key']:
            print("      s3-secret-key: REDACTED (non-empty — enter manually during recreate_backup_targets.sh)")
        else:
            print("      s3-secret-key: (empty in charm config — enter manually during recreate_backup_targets.sh)")
        t['s3-secret-key'] = 'REDACTED'

output = {
    '_collected_at': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    '_source_charm': os.environ.get('_APP', 'trilio-wlm'),
    'backup_targets': targets,
}

with open(output_path, 'w') as f:
    json.dump(output, f, indent=2)
    f.write('\n')

print("  Written: " + output_path)
PYEOF

log ""
log "Done. Review $OUTPUT before proceeding with the upgrade."
log ""
log "Next steps:"
log "  1. Upgrade charms:    juju refresh trilio-wlm --channel 6.2/stable"
log "                        juju refresh trilio-dm-api --channel 6.2/stable"
log "                        juju refresh trilio-data-mover --channel 6.2/stable"
log "                        juju refresh trilio-horizon-plugin --channel 6.2/stable"
log "  2. Unmount old BTs:   bash unmount_old_backup_targets.sh"
log "  3. Re-create BTs:     bash recreate_backup_targets.sh -f $OUTPUT --openrc /path/to/openrc"
