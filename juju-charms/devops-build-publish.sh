#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O Juju charms to Charmhub.
# Runs charmcraft clean, pack, and upload --release for each charm.
# Writes a build report to build-report-<timestamp>.txt when done.
#
# Usage:
#   bash devops-build-publish.sh [charm]
#
# Arguments:
#   charm  (optional) Build and release only this charm:
#            wlm | data-mover | dm-api | horizon-plugin
#          If omitted, all 4 charms are built and released.
#
# The release channel defaults to 6.0/candidate.
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

set -e

CHANNEL="${CHANNEL:-6.0/candidate}"

# Load Charmhub credentials non-interactively if not already set
CHARMHUB_CREDS_FILE="${CHARMHUB_CREDS_FILE:-$HOME/.charmhub-creds}"
if [ -z "${CHARMCRAFT_AUTH:-}" ] && [ -f "$CHARMHUB_CREDS_FILE" ]; then
    export CHARMCRAFT_AUTH
    CHARMCRAFT_AUTH=$(cat "$CHARMHUB_CREDS_FILE")
    echo "Loaded Charmhub credentials from $CHARMHUB_CREDS_FILE"
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
        echo "ERROR: Unknown charm '$SINGLE_CHARM'."
        echo "Valid options: ${ALL_CHARMS[*]}"
        exit 1
    fi
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_FILE="$BASE_DIR/build-report-$(date '+%Y%m%d-%H%M%S').txt"

# Result tracking (set by build_and_release_charm)
declare -A RESULT_STATUS
declare -A RESULT_REVISION
declare -A RESULT_FILE
_LAST_REVISION=""
_LAST_CHARM_FILE=""

echo "=================================================="
echo " T4O Juju Charms Build & Publish"
echo " Channel : $CHANNEL"
if [ -n "$SINGLE_CHARM" ]; then
echo " Charm   : $SINGLE_CHARM (single)"
else
echo " Charm   : all"
fi
echo "=================================================="

build_and_release_charm() {
    local SHORT_NAME="$1"
    local DIR_NAME="${CHARM_DIR_MAP[$SHORT_NAME]}"
    local CHARM_PATH="$BASE_DIR/$DIR_NAME"
    _LAST_REVISION=""
    _LAST_CHARM_FILE=""

    if [ ! -d "$CHARM_PATH" ]; then
        echo ""
        echo "SKIP: $DIR_NAME — directory not found"
        return 0
    fi

    echo ""
    echo "--------------------------------------------------"
    echo " Charm    : $DIR_NAME"
    echo " Channel  : $CHANNEL"
    echo "--------------------------------------------------"

    cd "$CHARM_PATH"

    echo " Cleaning previous build artifacts..."
    charmcraft clean

    echo " Removing any existing .charm files..."
    rm -f ./*.charm

    echo " Packing charm..."
    charmcraft pack

    # Find the built .charm file
    _LAST_CHARM_FILE=$(ls *.charm 2>/dev/null | head -1)
    if [ -z "$_LAST_CHARM_FILE" ]; then
        echo "ERROR: No .charm file produced in $CHARM_PATH"
        return 1
    fi

    echo " Uploading and releasing: $_LAST_CHARM_FILE → $CHANNEL"
    local UPLOAD_OUTPUT
    UPLOAD_OUTPUT=$(charmcraft upload "$_LAST_CHARM_FILE" --release "$CHANNEL" 2>&1)
    echo "$UPLOAD_OUTPUT"

    # Parse revision number from charmcraft upload output
    _LAST_REVISION=$(echo "$UPLOAD_OUTPUT" | grep -oP '(?i)Revision \K[0-9]+' | head -1)

    echo " Published : $DIR_NAME @ $CHANNEL (revision ${_LAST_REVISION:-unknown})"
}

# Build loop — errors inside build_and_release_charm are caught by the if
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
        RESULT_STATUS[$SHORT_NAME]="PASSED"
        RESULT_REVISION[$SHORT_NAME]="${_LAST_REVISION:--}"
        RESULT_FILE[$SHORT_NAME]="${_LAST_CHARM_FILE:--}"
        (( COUNT_PASSED++ )) || true
    else
        RESULT_STATUS[$SHORT_NAME]="FAILED"
        RESULT_REVISION[$SHORT_NAME]="-"
        RESULT_FILE[$SHORT_NAME]="${_LAST_CHARM_FILE:--}"
        (( COUNT_FAILED++ )) || true
    fi
done

# Write report to file and stdout
write_report() {
    local OUT="$1"
    printf "==========================================================\n" >> "$OUT"
    printf " T4O Juju Charms Build & Publish Report\n" >> "$OUT"
    printf " Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$OUT"
    printf " Channel : %s\n" "$CHANNEL" >> "$OUT"
    printf "==========================================================\n" >> "$OUT"
    printf "\n" >> "$OUT"
    printf " %-35s %-8s %-10s %s\n" "Charm" "Status" "Revision" "File" >> "$OUT"
    printf " %-35s %-8s %-10s %s\n" "-----" "------" "--------" "----" >> "$OUT"
    for SHORT_NAME in "${ALL_CHARMS[@]}"; do
        local DIR_NAME="${CHARM_DIR_MAP[$SHORT_NAME]}"
        local STATUS="${RESULT_STATUS[$SHORT_NAME]:-SKIPPED}"
        local REVISION="${RESULT_REVISION[$SHORT_NAME]:--}"
        local FILE="${RESULT_FILE[$SHORT_NAME]:--}"
        printf " %-35s %-8s %-10s %s\n" "$DIR_NAME" "$STATUS" "$REVISION" "$FILE" >> "$OUT"
    done
    printf "\n" >> "$OUT"
    printf "==========================================================\n" >> "$OUT"
    printf " Summary: %d passed | %d failed | %d skipped\n" "$COUNT_PASSED" "$COUNT_FAILED" "$COUNT_SKIPPED" >> "$OUT"
    printf "==========================================================\n" >> "$OUT"
}

# Write to report file
write_report "$REPORT_FILE"

# Print report to stdout
echo ""
cat "$REPORT_FILE"
echo ""
echo "Report saved to: $REPORT_FILE"

# Exit with error if any charm failed
if [ "$COUNT_FAILED" -gt 0 ]; then
    exit 1
fi
