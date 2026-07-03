#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O Juju charms to Charmhub.
# Runs charmcraft clean, pack, and upload --release for each charm.
#
# All verbose output (charmcraft logs) is written to build-<timestamp>.log.
# The terminal shows only a clean per-charm status report.
#
# Usage:
#   bash devops-build-publish.sh [charm]
#
# Arguments:
#   charm  (optional) Build and release only this charm:
#            wlm | data-mover | dm-api | horizon-plugin
#          If omitted, all 4 charms are built and released.
#
# The release channel defaults to 6.2/candidate.
# Override by setting the CHANNEL environment variable:
#   CHANNEL=latest/edge bash devops-build-publish.sh
#
# Charms:
#   charm-trilio-wlm              Workload Manager
#   charm-trilio-data-mover       Compute node Datamover
#   charm-trilio-dm-api           Control plane Datamover API
#   charm-trilio-horizon-plugin   OpenStack Horizon UI plugin
#
# Prerequisites:
#   - charmcraft must be installed
#   - Charmhub credentials available via one of:
#       a) CHARMCRAFT_AUTH env var (base64 credentials string)
#       b) Credentials file at ~/.charmhub-creds (export once with:
#            charmcraft login --export ~/.charmhub-creds)
#       c) Already logged in interactively (charmcraft login)
#
# Examples:
#   bash devops-build-publish.sh
#   bash devops-build-publish.sh wlm
#   CHANNEL=latest/edge bash devops-build-publish.sh data-mover

set -uo pipefail

CHANNEL="${CHANNEL:-6.2/candidate}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$BASE_DIR/build-$(date '+%Y%m%d-%H%M%S').log"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# say  : print to screen AND append to log
# log  : append to log only (for verbose command output)
say()  { printf "%s\n" "$*" | tee -a "$LOG_FILE"; }
sayf() { printf "$@" | tee -a "$LOG_FILE"; }
log()  { printf "%s\n" "$*" >> "$LOG_FILE"; }

step_ok()   { printf "${GREEN}%-12s${NC}\n" "OK"     | tee -a "$LOG_FILE"; }
step_fail() { printf "${RED}%-12s${NC}\n"   "FAILED" | tee -a "$LOG_FILE"; }
step_skip() { printf "${YELLOW}%-12s${NC}\n" "SKIPPED" | tee -a "$LOG_FILE"; }

# Load Charmhub credentials non-interactively if not already set
CHARMHUB_CREDS_FILE="${CHARMHUB_CREDS_FILE:-$HOME/.charmhub-creds}"
if [ -z "${CHARMCRAFT_AUTH:-}" ] && [ -f "$CHARMHUB_CREDS_FILE" ]; then
    export CHARMCRAFT_AUTH
    CHARMCRAFT_AUTH=$(cat "$CHARMHUB_CREDS_FILE")
    say "Loaded Charmhub credentials from $CHARMHUB_CREDS_FILE"
fi

# Validate credentials are still active before starting any builds
if ! charmcraft whoami >>"$LOG_FILE" 2>&1; then
    say "ERROR: Charmhub credentials are expired or invalid."
    say ""
    say "Re-export credentials with a 1-year TTL using:"
    say "  charmcraft login --export $CHARMHUB_CREDS_FILE --ttl 31536000"
    exit 1
fi

usage() {
    cat <<EOF
Usage: $0 [charm]

  charm  (optional) Build and release a single charm.
         If omitted, all 4 charms are built and released.

Charm names (short):
  wlm             charm-trilio-wlm
  data-mover      charm-trilio-data-mover
  dm-api          charm-trilio-dm-api
  horizon-plugin  charm-trilio-horizon-plugin

Channel: $CHANNEL  (override with CHANNEL=<channel>)

Charmhub authentication (non-interactive):
  Export credentials once:
    charmcraft login --export ~/.charmhub-creds
  The script loads ~/.charmhub-creds automatically on subsequent runs.
  Or pass credentials directly:
    CHARMCRAFT_AUTH=\$(cat ~/.charmhub-creds) $0

Examples:
  $0
  $0 wlm
  CHANNEL=latest/edge $0 data-mover

Options:
  -h, --help   Show this help message and exit.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -gt 1 ]; then
    usage
    exit 1
fi

SINGLE_CHARM="${1:-}"

# Map short name → directory name
declare -A CHARM_DIR_MAP=(
    [wlm]="charm-trilio-wlm"
    [data-mover]="charm-trilio-data-mover"
    [dm-api]="charm-trilio-dm-api"
    [horizon-plugin]="charm-trilio-horizon-plugin"
)

ALL_CHARMS=(wlm data-mover dm-api horizon-plugin)

if [ -n "$SINGLE_CHARM" ]; then
    if [ -z "${CHARM_DIR_MAP[$SINGLE_CHARM]+x}" ]; then
        say "ERROR: Unknown charm '$SINGLE_CHARM'."
        say "Valid options: ${ALL_CHARMS[*]}"
        exit 1
    fi
fi

say "=================================================="
say " T4O Juju Charms Build & Publish"
say " Date    : $(date '+%Y-%m-%d %H:%M:%S')"
say " Channel : $CHANNEL"
if [ -n "$SINGLE_CHARM" ]; then
say " Charm   : $SINGLE_CHARM (single)"
else
say " Charm   : all"
fi
say " Log     : $LOG_FILE"
say "=================================================="

# Result tracking
declare -A RESULT_STATUS
declare -A RESULT_REVISION
declare -A RESULT_FILE
_LAST_REVISION=""
_LAST_CHARM_FILE=""

build_and_release_charm() {
    local SHORT_NAME="$1"
    local DIR_NAME="${CHARM_DIR_MAP[$SHORT_NAME]}"
    local CHARM_PATH="$BASE_DIR/$DIR_NAME"
    _LAST_REVISION=""
    _LAST_CHARM_FILE=""

    say ""
    say "  ${BOLD}${DIR_NAME}${NC}"

    if [ ! -d "$CHARM_PATH" ]; then
        sayf "    %-12s" "dir-check"
        step_skip
        RESULT_STATUS[$SHORT_NAME]="DIR-NOT-FOUND"
        return 0
    fi

    cd "$CHARM_PATH"

    # Clean
    sayf "    %-12s" "clean"
    log "--- clean: $DIR_NAME ---"
    if charmcraft clean >>"$LOG_FILE" 2>&1; then
        step_ok
    else
        step_fail
        RESULT_STATUS[$SHORT_NAME]="CLEAN-FAILED"
        return 1
    fi

    # Remove stale .charm files
    rm -f ./*.charm

    # Pack / Build
    sayf "    %-12s" "build"
    log "--- build: $DIR_NAME ---"
    if charmcraft pack >>"$LOG_FILE" 2>&1; then
        _LAST_CHARM_FILE=$(ls ./*.charm 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "")
        step_ok
        log "    built: $_LAST_CHARM_FILE"
    else
        step_fail
        RESULT_STATUS[$SHORT_NAME]="BUILD-FAILED"
        return 1
    fi

    if [ -z "$_LAST_CHARM_FILE" ]; then
        sayf "    %-12s" "build"
        step_fail
        log "    ERROR: no .charm file found after pack"
        RESULT_STATUS[$SHORT_NAME]="BUILD-FAILED"
        return 1
    fi

    # Upload & release
    sayf "    %-12s" "publish"
    log "--- publish: $DIR_NAME → $CHANNEL ---"
    local UPLOAD_OUTPUT
    if UPLOAD_OUTPUT=$(charmcraft upload "$_LAST_CHARM_FILE" --release "$CHANNEL" 2>&1); then
        log "$UPLOAD_OUTPUT"
        _LAST_REVISION=$(echo "$UPLOAD_OUTPUT" | grep -oP '(?i)Revision \K[0-9]+' | head -1)
        step_ok
        log "    revision: ${_LAST_REVISION:-unknown}"
    else
        log "$UPLOAD_OUTPUT"
        step_fail
        RESULT_STATUS[$SHORT_NAME]="PUBLISH-FAILED"
        return 1
    fi

    return 0
}

# Build loop
COUNT_PASSED=0
COUNT_FAILED=0
COUNT_SKIPPED=0

for SHORT_NAME in "${ALL_CHARMS[@]}"; do
    if [ -n "$SINGLE_CHARM" ] && [ "$SINGLE_CHARM" != "$SHORT_NAME" ]; then
        RESULT_STATUS[$SHORT_NAME]="SKIPPED"
        RESULT_REVISION[$SHORT_NAME]="-"
        RESULT_FILE[$SHORT_NAME]="-"
        (( COUNT_SKIPPED++ )) || true
        continue
    fi

    if build_and_release_charm "$SHORT_NAME"; then
        RESULT_STATUS[$SHORT_NAME]="${RESULT_STATUS[$SHORT_NAME]:-PASSED}"
        RESULT_REVISION[$SHORT_NAME]="${_LAST_REVISION:--}"
        RESULT_FILE[$SHORT_NAME]="${_LAST_CHARM_FILE:--}"
        [[ "${RESULT_STATUS[$SHORT_NAME]}" == "PASSED" ]] && (( COUNT_PASSED++ )) || true
        [[ "${RESULT_STATUS[$SHORT_NAME]}" == "DIR-NOT-FOUND" ]] && (( COUNT_SKIPPED++ )) || true
    else
        RESULT_STATUS[$SHORT_NAME]="${RESULT_STATUS[$SHORT_NAME]:-FAILED}"
        RESULT_REVISION[$SHORT_NAME]="-"
        RESULT_FILE[$SHORT_NAME]="${_LAST_CHARM_FILE:--}"
        (( COUNT_FAILED++ )) || true
    fi
done

# Summary table
say ""
say "=========================================================="
say " Build & Publish Summary"
say " Date    : $(date '+%Y-%m-%d %H:%M:%S')"
say " Channel : $CHANNEL"
say "=========================================================="
say "$(printf " %-35s %-16s %-10s %s" "Charm" "Status" "Revision" "File")"
say "$(printf " %-35s %-16s %-10s %s" "-----" "------" "--------" "----")"
for SHORT_NAME in "${ALL_CHARMS[@]}"; do
    DIR_NAME="${CHARM_DIR_MAP[$SHORT_NAME]}"
    STATUS="${RESULT_STATUS[$SHORT_NAME]:-SKIPPED}"
    REVISION="${RESULT_REVISION[$SHORT_NAME]:--}"
    FILE="${RESULT_FILE[$SHORT_NAME]:--}"
    # Colour the status field
    case "$STATUS" in
        PASSED)       COLOR="$GREEN" ;;
        SKIPPED|DIR-NOT-FOUND) COLOR="$YELLOW" ;;
        *)            COLOR="$RED" ;;
    esac
    printf " %-35s ${COLOR}%-16s${NC} %-10s %s\n" \
        "$DIR_NAME" "$STATUS" "$REVISION" "$FILE" | tee -a "$LOG_FILE"
done
say ""
say " Result : ${COUNT_PASSED} passed | ${COUNT_FAILED} failed | ${COUNT_SKIPPED} skipped"
say " Log    : $LOG_FILE"
say "=========================================================="

# Exit non-zero if any charm failed so CI can detect partial failures
[ "$COUNT_FAILED" -gt 0 ] && exit 1 || exit 0
