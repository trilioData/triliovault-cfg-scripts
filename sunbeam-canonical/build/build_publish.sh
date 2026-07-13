#!/usr/bin/env bash
# build_publish.sh — Build and publish TrilioVault Sunbeam charms to Charmhub
#
# Packs each charm with charmcraft, uploads to Charmhub, and releases to the
# specified channel. Requires charmcraft installed and logged in:
#   sudo snap install charmcraft --classic
#   charmcraft login
#
# Usage (run from any directory):
#   bash sunbeam-canonical/build/build_publish.sh [OPTIONS]
#
# Options:
#   --channel <CHANNEL>   Charmhub channel to release to (default: 2024.1/edge)
#   --build-only          Pack charms but skip upload and release
#   --publish-only        Upload/release pre-built .charm files, skip pack
#   --charm <NAME>        Target one charm only (repeatable); default: all four
#   -h, --help            Show this help
#
# Charm names on Charmhub:
#   trilio-wlm-k8s
#   trilio-dm-api-k8s
#   trilio-dms-k8s
#   trilio-data-mover-sunbeam

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARMS_DIR="$(dirname "$SCRIPT_DIR")/charms"

CHANNEL="2024.1/edge"
BUILD_ONLY=false
PUBLISH_ONLY=false
SELECTED_CHARMS=()

# Charmhub name → source directory under charms/
declare -A CHARM_DIR_MAP=(
    [trilio-wlm-k8s]="trilio-wlm-k8s"
    [trilio-dm-api-k8s]="trilio-dm-api-k8s"
    [trilio-dms-k8s]="trilio-dms-k8s"
    [trilio-data-mover-sunbeam]="trilio-data-mover"
)
ALL_CHARMS=(trilio-wlm-k8s trilio-dm-api-k8s trilio-dms-k8s trilio-data-mover-sunbeam)

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --channel)       CHANNEL="$2";            shift 2 ;;
        --build-only)    BUILD_ONLY=true;          shift   ;;
        --publish-only)  PUBLISH_ONLY=true;        shift   ;;
        --charm)         SELECTED_CHARMS+=("$2");  shift 2 ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ ${#SELECTED_CHARMS[@]} -eq 0 ]] && SELECTED_CHARMS=("${ALL_CHARMS[@]}")

for charm in "${SELECTED_CHARMS[@]}"; do
    [[ -v CHARM_DIR_MAP[$charm] ]] || die "Unknown charm '$charm'. Valid: ${ALL_CHARMS[*]}"
done

log "Charms       : ${SELECTED_CHARMS[*]}"
log "Channel      : $CHANNEL"
log "Build-only   : $BUILD_ONLY"
log "Publish-only : $PUBLISH_ONLY"
echo

# ---------------------------------------------------------------------------
# Step 1 — Pack
# ---------------------------------------------------------------------------
if [[ "$PUBLISH_ONLY" != "true" ]]; then
    for charm in "${SELECTED_CHARMS[@]}"; do
        charm_dir="$CHARMS_DIR/${CHARM_DIR_MAP[$charm]}"
        [[ -d "$charm_dir" ]] || die "Charm directory not found: $charm_dir"

        log "[$charm] Packing ..."
        (cd "$charm_dir" && charmcraft pack --verbose)
        log "[$charm] Pack complete"
    done
fi

[[ "$BUILD_ONLY" == "true" ]] && { log "Build-only mode — done."; exit 0; }

# ---------------------------------------------------------------------------
# Step 2 — Upload and release
# ---------------------------------------------------------------------------
for charm in "${SELECTED_CHARMS[@]}"; do
    charm_dir="$CHARMS_DIR/${CHARM_DIR_MAP[$charm]}"

    # charmcraft pack writes the .charm file into the charm directory.
    # Filename pattern: <charm-name>_ubuntu-22.04-amd64.charm
    charm_file=$(ls "$charm_dir"/${charm}_*.charm 2>/dev/null | sort -V | tail -1)
    [[ -n "$charm_file" ]] || die "No .charm file found for '$charm' in $charm_dir. Run without --publish-only to build first."

    log "[$charm] Uploading $charm_file ..."
    upload_out=$(charmcraft upload "$charm_file" --format json)
    revision=$(python3 -c "import sys, json; print(json.load(sys.stdin)['revision'])" <<< "$upload_out")
    log "[$charm] Uploaded as revision $revision"

    log "[$charm] Releasing revision $revision to $CHANNEL ..."
    charmcraft release "$charm" --revision "$revision" --channel "$CHANNEL"
    log "[$charm] Released to $CHANNEL"
done

echo
log "All charms published to channel: $CHANNEL"
