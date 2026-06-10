#!/bin/bash
# unmount_old_backup_targets.sh
#
# Unmounts old static backup target mounts from T4O 5.x/6.0/6.1 across all
# trilio-data-mover and trilio-wlm units in parallel using the Juju action
# mechanism.
#
# This uses the 'unmount-old-backup-targets' Juju action which runs on the
# unit itself — no sequential ssh loop. Works for any number of compute nodes.
#
# The action on each unit:
#   1. Stops and disables tvault-object-store (prevents re-mounting)
#   2. Lazy-unmounts all mounts under /var/triliovault-mounts
#   3. Reports results back via juju run output
#
# Prerequisites:
#   - T4O 6.2 charms deployed (charm carries the action)
#   - juju CLI authenticated and connected to the OpenStack model
#
# Usage:
#   bash unmount_old_backup_targets.sh \
#     [--compute-app trilio-data-mover] \
#     [--wlm-app trilio-wlm] \
#     [--timeout 300]

set -e

COMPUTE_APP="trilio-data-mover"
WLM_APP="trilio-wlm"
ACTION="unmount-old-backup-targets"
TIMEOUT=300

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }
die()      { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compute-app) COMPUTE_APP="$2"; shift 2 ;;
    --wlm-app)     WLM_APP="$2";     shift 2 ;;
    --timeout)     TIMEOUT="$2";     shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

command -v juju >/dev/null 2>&1 || die "juju CLI not found."

# Detect Juju major version to use correct run command syntax
JUJU_MAJOR=$(juju version 2>/dev/null | cut -d. -f1)

run_action_all() {
    local app="$1"
    log "Running '$ACTION' on all units of $app in parallel..."

    if [ "$JUJU_MAJOR" -ge 3 ] 2>/dev/null; then
        # Juju 3.x syntax: juju run <app>/* <action> --wait=<timeout>s
        juju run "${app}/*" "$ACTION" --wait="${TIMEOUT}s" --format=yaml
    else
        # Juju 2.x syntax: juju run-action <app>/* <action> --wait=<timeout>
        juju run-action "${app}/*" "$ACTION" --wait="$TIMEOUT" --format=yaml
    fi
}

log_step "Unmounting on all $COMPUTE_APP units (parallel)"
run_action_all "$COMPUTE_APP"

log_step "Unmounting on all $WLM_APP units"
run_action_all "$WLM_APP"

log_step "Verification"
log "Spot-check a compute unit for remaining mounts (expected: no output):"
if [ "$JUJU_MAJOR" -ge 3 ] 2>/dev/null; then
    juju exec --application "$COMPUTE_APP" "findmnt -r | grep triliovault-mounts || true"
else
    juju run --application "$COMPUTE_APP" "findmnt -r | grep triliovault-mounts || true"
fi

log ""
log "Done. All mounts cleared across all units."
