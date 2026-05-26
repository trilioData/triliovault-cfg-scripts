#!/bin/bash
# unmount_old_backup_targets.sh
#
# Unmounts old static backup target mounts from nova-compute and WLM nodes
# before or after upgrading to T4O 6.2.
#
# In T4O 5.x/6.0/6.1, backup targets (NFS and S3/FUSE) were statically mounted
# at deploy time by the tvault-object-store service. In T4O 6.2, the DMS service
# mounts them dynamically on demand. Old static mounts must be removed.
#
# This script:
#   1. Stops and disables tvault-object-store on each node (prevents re-mounting)
#   2. Lazy-unmounts all mounts under /var/triliovault-mounts on each node
#   3. Verifies no mounts remain
#
# Prerequisites:
#   - juju CLI authenticated and connected to the OpenStack model
#   - SSH access to all nova-compute and trilio-wlm units (via juju ssh)
#
# Usage:
#   bash unmount_old_backup_targets.sh \
#     [--compute-app nova-compute] \
#     [--wlm-app trilio-wlm] \
#     [--mount-base /var/triliovault-mounts]

set -e

COMPUTE_APP="nova-compute"
WLM_APP="trilio-wlm"
MOUNT_BASE="/var/triliovault-mounts"

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }
die()      { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compute-app)  COMPUTE_APP="$2";  shift 2 ;;
    --wlm-app)      WLM_APP="$2";      shift 2 ;;
    --mount-base)   MOUNT_BASE="$2";   shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

command -v juju   >/dev/null 2>&1 || die "juju CLI not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."

get_units() {
    local app="$1"
    juju status --format json 2>/dev/null \
      | python3 -c "
import sys, json
status = json.load(sys.stdin)
units = status.get('applications', {}).get('$app', {}).get('units', {})
print('\n'.join(units.keys()))
" 2>/dev/null || true
}

unmount_on_unit() {
    local unit="$1"
    log "Processing $unit..."
    juju ssh "$unit" "sudo bash -s -- '$MOUNT_BASE'" <<'ENDSSH'
set -e
MOUNT_BASE="$1"

# Stop tvault-object-store if running (it will re-mount on start)
if systemctl list-units --full --all 2>/dev/null | grep -q "tvault-object-store"; then
    if systemctl is-active --quiet tvault-object-store 2>/dev/null; then
        echo "  Stopping tvault-object-store..."
        sudo systemctl stop tvault-object-store
    fi
    sudo systemctl disable tvault-object-store 2>/dev/null || true
    echo "  tvault-object-store stopped and disabled."
else
    echo "  tvault-object-store not present (already removed or not installed)."
fi

# Find and unmount all triliovault mounts
mounts=$(findmnt -rn -o TARGET | grep "$MOUNT_BASE" 2>/dev/null || true)
if [ -z "$mounts" ]; then
    echo "  No mounts found under $MOUNT_BASE"
else
    echo "  Found mounts:"
    echo "$mounts" | sed 's/^/    /'
    while IFS= read -r mount; do
        echo "  Unmounting (lazy): $mount"
        sudo umount -l "$mount" 2>/dev/null || echo "  WARNING: Failed to unmount $mount (may already be gone)"
    done <<< "$mounts"
fi

# Verify
remaining=$(findmnt -rn -o TARGET | grep "$MOUNT_BASE" 2>/dev/null || true)
if [ -z "$remaining" ]; then
    echo "  All mounts cleared on $(hostname)."
else
    echo "  WARNING: Mounts still present on $(hostname):"
    echo "$remaining" | sed 's/^/    /'
fi
ENDSSH
}

log_step "Collecting unit lists"

COMPUTE_UNITS=$(get_units "$COMPUTE_APP")
WLM_UNITS=$(get_units "$WLM_APP")

if [ -z "$COMPUTE_UNITS" ] && [ -z "$WLM_UNITS" ]; then
    die "No units found for '$COMPUTE_APP' or '$WLM_APP'. Check juju status."
fi

log_step "Unmounting on nova-compute units ($COMPUTE_APP)"
if [ -z "$COMPUTE_UNITS" ]; then
    log "No $COMPUTE_APP units found — skipping."
else
    while IFS= read -r unit; do
        [ -n "$unit" ] && unmount_on_unit "$unit"
    done <<< "$COMPUTE_UNITS"
fi

log_step "Unmounting on WLM unit ($WLM_APP)"
if [ -z "$WLM_UNITS" ]; then
    log "No $WLM_APP units found — skipping."
else
    while IFS= read -r unit; do
        [ -n "$unit" ] && unmount_on_unit "$unit"
    done <<< "$WLM_UNITS"
fi

log_step "Summary"
log "Unmount complete. Verify with:"
log "  juju ssh nova-compute/0 'findmnt -r | grep triliovault-mounts'"
log "  juju ssh trilio-wlm/0  'findmnt -r | grep triliovault-mounts'"
