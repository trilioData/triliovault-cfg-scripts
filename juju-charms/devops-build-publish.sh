#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O Juju charms to Charmhub.
# Runs charmcraft clean, pack, and release for each charm.
#
# Usage:
#   bash devops-build-publish.sh <channel> [charm]
#
# Arguments:
#   channel  Charmhub release channel, e.g. latest/edge | 6.2/stable
#   charm    (optional) Build and release only this charm:
#              wlm | data-mover | dm-api | horizon-plugin
#            If omitted, all 4 charms are built and released.
#
# Charms:
#   charm-trilio-wlm              Workload Manager
#   charm-trilio-data-mover       Compute node Datamover
#   charm-trilio-dm-api           Control plane Datamover API
#   charm-trilio-horizon-plugin   OpenStack Horizon UI plugin
#
# Prerequisites:
#   - charmcraft must be installed and logged in (charmcraft login)
#
# Examples:
#   bash devops-build-publish.sh latest/edge
#   bash devops-build-publish.sh 6.2/stable wlm

set -e

usage() {
    cat <<EOF
Usage: $0 <channel> [charm]

  channel  Charmhub release channel, e.g. latest/edge | 6.2/stable
  charm    (optional) Build and release a single charm.
           If omitted, all 4 charms are built and released.

Charm names (short):
  wlm             charm-trilio-wlm
  data-mover      charm-trilio-data-mover
  dm-api          charm-trilio-dm-api
  horizon-plugin  charm-trilio-horizon-plugin

Examples:
  $0 latest/edge
  $0 6.2/stable wlm
  $0 latest/edge data-mover

Options:
  -h, --help   Show this help message and exit.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
    exit 1
fi

CHANNEL="$1"
SINGLE_CHARM="${2:-}"

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

    if [ ! -d "$CHARM_PATH" ]; then
        echo ""
        echo "SKIP: $DIR_NAME — directory not found"
        return
    fi

    echo ""
    echo "--------------------------------------------------"
    echo " Charm    : $DIR_NAME"
    echo " Channel  : $CHANNEL"
    echo "--------------------------------------------------"

    cd "$CHARM_PATH"

    echo " Cleaning previous build artifacts..."
    charmcraft clean

    echo " Packing charm..."
    charmcraft pack

    # Find the built .charm file
    CHARM_FILE=$(ls *.charm 2>/dev/null | head -1)
    if [ -z "$CHARM_FILE" ]; then
        echo "ERROR: No .charm file produced in $CHARM_PATH"
        exit 1
    fi

    echo " Uploading and releasing: $CHARM_FILE → $CHANNEL"
    charmcraft upload "$CHARM_FILE" --release "$CHANNEL"

    echo " Published : $DIR_NAME @ $CHANNEL"
}

for SHORT_NAME in "${ALL_CHARMS[@]}"; do
    if [ -n "$SINGLE_CHARM" ] && [ "$SINGLE_CHARM" != "$SHORT_NAME" ]; then
        continue
    fi
    build_and_release_charm "$SHORT_NAME"
done

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
