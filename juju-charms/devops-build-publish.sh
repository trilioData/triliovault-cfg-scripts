#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O Juju charms to Charmhub.
# Runs charmcraft clean, pack, and upload --release for each charm.
# All output (logs + summary) is written to build-report-<timestamp>.txt
# and printed to the console simultaneously.
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

# Per-charm binary wheels to download at build time (not committed to git).
# Required when charmcraft fetches source tarballs whose build deps are
# incompatible with the charm's pinned setuptools version.
# These are added to src/wheelhouse/ before charmcraft pack and removed
# immediately after so they do not persist in the source tree.
declare -A CHARM_EXTRA_WHEELS=(
    [wlm]="setuptools-scm==9.2.2 vcs-versioning==0.0.1 packaging==26.2"
    [dm-api]="setuptools-scm==9.2.2 vcs-versioning==0.0.1 packaging==26.2"
)

if [ -n "$SINGLE_CHARM" ]; then
    if [ -z "${CHARM_DIR_MAP[$SINGLE_CHARM]+x}" ]; then
        echo "ERROR: Unknown charm '$SINGLE_CHARM'."
        echo "Valid options: ${ALL_CHARMS[*]}"
        exit 1
    fi
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_FILE="$BASE_DIR/build-report-$(date '+%Y%m%d-%H%M%S').txt"

# Tee all stdout and stderr to the report file and the console simultaneously
exec > >(tee "$REPORT_FILE") 2>&1

echo "=================================================="
echo " T4O Juju Charms Build & Publish"
echo " Date    : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Channel : $CHANNEL"
if [ -n "$SINGLE_CHARM" ]; then
echo " Charm   : $SINGLE_CHARM (single)"
else
echo " Charm   : all"
fi
echo " Report  : $REPORT_FILE"
echo "=================================================="

# Result tracking (populated by build_and_release_charm)
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

    # Download per-charm binary wheels at build time (not committed to git)
    local EXTRA_WHEELS="${CHARM_EXTRA_WHEELS[$SHORT_NAME]:-}"
    local -a _BUILD_WHEELS=()
    if [ -n "$EXTRA_WHEELS" ]; then
        echo " Downloading build-time binary wheels: $EXTRA_WHEELS"
        local _wh_before
        _wh_before=$(ls src/wheelhouse/*.whl 2>/dev/null | sort || echo "")
        # shellcheck disable=SC2086
        python3 -m pip download $EXTRA_WHEELS \
            --dest src/wheelhouse \
            --only-binary :all: \
            --quiet
        while IFS= read -r whl; do
            [ -n "$whl" ] && _BUILD_WHEELS+=("$whl")
        done < <(comm -13 \
            <(echo "$_wh_before") \
            <(ls src/wheelhouse/*.whl 2>/dev/null | sort || echo ""))
        echo " Downloaded: ${_BUILD_WHEELS[*]:-none}"
    fi

    echo " Cleaning previous build artifacts..."
    charmcraft clean

    echo " Removing any existing .charm files..."
    rm -f ./*.charm

    echo " Packing charm..."
    charmcraft pack

    # Remove build-time wheels — they were only needed for the pack step
    if [ "${#_BUILD_WHEELS[@]}" -gt 0 ]; then
        echo " Removing build-time wheels from src/wheelhouse/ ..."
        rm -f "${_BUILD_WHEELS[@]}"
    fi

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

# Print summary table (captured by tee into report file automatically)
echo ""
echo "=========================================================="
echo " Build & Publish Summary"
echo " Date    : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Channel : $CHANNEL"
echo "=========================================================="
printf " %-35s %-8s %-10s %s\n" "Charm" "Status" "Revision" "File"
printf " %-35s %-8s %-10s %s\n" "-----" "------" "--------" "----"
for SHORT_NAME in "${ALL_CHARMS[@]}"; do
    DIR_NAME="${CHARM_DIR_MAP[$SHORT_NAME]}"
    STATUS="${RESULT_STATUS[$SHORT_NAME]:-SKIPPED}"
    REVISION="${RESULT_REVISION[$SHORT_NAME]:--}"
    FILE="${RESULT_FILE[$SHORT_NAME]:--}"
    printf " %-35s %-8s %-10s %s\n" "$DIR_NAME" "$STATUS" "$REVISION" "$FILE"
done
echo ""
echo " Result: $COUNT_PASSED passed | $COUNT_FAILED failed | $COUNT_SKIPPED skipped"
echo "=========================================================="

# Exit non-zero if any charm failed so CI can detect partial failures
if [ "$COUNT_FAILED" -gt 0 ]; then
    echo ""
    echo "Build report: $REPORT_FILE"
    exit 1
fi

echo ""
echo "Build report: $REPORT_FILE"
