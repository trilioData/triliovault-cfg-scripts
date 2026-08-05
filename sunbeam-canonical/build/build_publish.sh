#!/usr/bin/env bash
# build_publish.sh — Build and/or publish TrilioVault Sunbeam charms to Charmhub
#
# Packs charms with charmcraft and/or uploads and releases them to Charmhub.
# Requires charmcraft installed: sudo snap install charmcraft --classic
#
# Usage (run from any directory):
#   bash sunbeam-canonical/build/build_publish.sh --charms <all|charm[,...]> --mode <MODE> [OPTIONS]
#
# Options:
#   --charms   'all' or comma-separated charm names
#   --mode     build-only        Pack charms; do not upload or release
#              publish-only      Upload/release pre-built .charm files; skip pack
#              build-and-publish Pack, upload, and release charms
#   --channel  Charmhub channel to release to (required — no default; always
#              use the full track/risk form, e.g. 6.2/candidate)
#
# Charm names on Charmhub:
#   trilio-wlm-k8s            (one OCI image resource: trilio-wlm-image —
#                              both the trilio-wlm and trilio-dms containers
#                              use the same image; no separate DMS image)
#   trilio-dm-api-k8s
#   trilio-data-mover-sunbeam
#
# Note: there is no separate trilio-dms-k8s charm as of 2026-07-25 — the
# Dynamic Mount Service control-plane instance is now a second container
# embedded directly in trilio-wlm-k8s's own pod (1:1 with each WLM replica).
# Both containers use the trilio-wlm image (it already includes
# python3-trilio-dms and python3-s3-fuse-plugin).
#
# OCI image resources are NOT uploaded by this script — it only re-releases
# whatever resource revisions are already on Charmhub. If you've rebuilt any
# image (via devops-build-publish.sh), upload it as a fresh resource first:
#   charmcraft upload-resource trilio-wlm-k8s trilio-wlm-image --image=docker.io/trilio/trilio-wlm-canonical:<tag>
#   charmcraft upload-resource trilio-dm-api-k8s trilio-dm-api-image --image=docker.io/trilio/trilio-datamover-api-canonical:<tag>
# then note the new resource revision number(s) and pass them via
# `charmcraft release ... --resource=<name>:<rev>` yourself — this script
# does not currently automate that step.
#
# Examples:
#   bash build_publish.sh --charms all --mode build-and-publish --channel 6.2/candidate
#   bash build_publish.sh --charms trilio-wlm-k8s,trilio-dm-api-k8s --mode build-only
#   bash build_publish.sh --charms all --mode publish-only --channel 6.2/candidate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARMS_DIR="$(dirname "$SCRIPT_DIR")/charms"

CHANNEL=""
MODE=""
CHARMS_ARG=""

# Charmhub name → source directory under charms/
declare -A CHARM_DIR_MAP=(
    [trilio-wlm-k8s]="trilio-wlm-k8s"
    [trilio-dm-api-k8s]="trilio-dm-api-k8s"
    [trilio-data-mover-sunbeam]="trilio-data-mover-sunbeam"
)
ALL_CHARMS=(trilio-wlm-k8s trilio-dm-api-k8s trilio-data-mover-sunbeam)

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 --charms <all|charm[,charm,...]> --mode <MODE> [OPTIONS]

  --charms   'all' or comma-separated charm names
  --mode     build-only        Pack charms; do not upload or release
             publish-only      Upload/release pre-built .charm files; skip pack
             build-and-publish Pack, upload, and release charms
  --channel  Charmhub channel — required for publish-only/build-and-publish.
             Always use the full track/risk form, e.g. 6.2/candidate.

Charms:
  trilio-wlm-k8s            WorkloadManager (k8s) — single OCI resource
                             trilio-wlm-image used for both containers
  trilio-dm-api-k8s         DataMover API (k8s)
  trilio-data-mover-sunbeam DataMover on compute nodes (machine subordinate)

Note: there is no separate trilio-dms-k8s charm or trilio-dms Docker image.
DMS is embedded as a second container in trilio-wlm-k8s's pod, using the
same trilio-wlm-canonical image (which already includes python3-trilio-dms).
This script does NOT upload OCI image resources — if you rebuilt an image,
upload it first with 'charmcraft upload-resource' (see top of this script).

Examples:
  $0 --charms all --mode build-and-publish --channel 6.2/candidate
  $0 --charms trilio-wlm-k8s,trilio-dm-api-k8s --mode build-only
  $0 --charms all --mode publish-only --channel 6.2/candidate

Options:
  -h, --help   Show this help and exit.
EOF
}

check_charmcraft_login() {
    command -v charmcraft > /dev/null 2>&1 \
        || die "charmcraft not installed. Run: sudo snap install charmcraft --classic"
    charmcraft whoami > /dev/null 2>&1 \
        || die "Not logged in to Charmhub. Run: charmcraft login"
    log "Charmhub login: OK ($(charmcraft whoami 2>/dev/null | awk '/^username:/{print $2}'))"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --charms)
            [[ -n "${2:-}" ]] || die "--charms requires a value"
            CHARMS_ARG="$2"; shift 2 ;;
        --mode)
            [[ -n "${2:-}" ]] || die "--mode requires a value"
            MODE="$2"; shift 2 ;;
        --channel)
            [[ -n "${2:-}" ]] || die "--channel requires a value"
            CHANNEL="$2"; shift 2 ;;
        *)
            die "Unknown option: $1" ;;
    esac
done

[[ -n "$CHARMS_ARG" ]] || { usage >&2; die "--charms is required ('all' or comma-separated charm names)"; }
[[ -n "$MODE" ]]       || { usage >&2; die "--mode is required (build-only | publish-only | build-and-publish)"; }

case "$MODE" in
    build-only|publish-only|build-and-publish) ;;
    *) die "Invalid --mode '$MODE'. Use: build-only | publish-only | build-and-publish" ;;
esac

if [[ "$MODE" != "build-only" ]]; then
    [[ -n "$CHANNEL" ]] || die "--channel is required for mode '$MODE' (e.g. 6.2/candidate)"
fi

# Expand 'all' or validate comma-separated names
SELECTED_CHARMS=()
if [[ "$CHARMS_ARG" == "all" ]]; then
    SELECTED_CHARMS=("${ALL_CHARMS[@]}")
else
    IFS=',' read -ra SELECTED_CHARMS <<< "$CHARMS_ARG"
    for charm in "${SELECTED_CHARMS[@]}"; do
        [[ -v CHARM_DIR_MAP[$charm] ]] || die "Unknown charm '$charm'. Valid: ${ALL_CHARMS[*]}"
    done
fi

# Pre-flight: Charmhub login only needed when uploading/releasing
if [[ "$MODE" != "build-only" ]]; then
    check_charmcraft_login
fi

log "Charms  : ${SELECTED_CHARMS[*]}"
log "Channel : $CHANNEL"
log "Mode    : $MODE"
echo

# ---------------------------------------------------------------------------
# Step 1 — Pack
# ---------------------------------------------------------------------------
if [[ "$MODE" != "publish-only" ]]; then
    for charm in "${SELECTED_CHARMS[@]}"; do
        charm_dir="$CHARMS_DIR/${CHARM_DIR_MAP[$charm]}"
        [[ -d "$charm_dir" ]] || die "Charm directory not found: $charm_dir"

        log "[$charm] Packing ..."
        (cd "$charm_dir" && charmcraft pack --verbose)
        log "[$charm] Pack complete"
    done
fi

[[ "$MODE" == "build-only" ]] && { log "Build-only mode — done."; exit 0; }

# ---------------------------------------------------------------------------
# Step 2 — Upload and release
# ---------------------------------------------------------------------------
for charm in "${SELECTED_CHARMS[@]}"; do
    charm_dir="$CHARMS_DIR/${CHARM_DIR_MAP[$charm]}"

    charm_file=$(ls "$charm_dir"/${charm}_*.charm 2>/dev/null | sort -V | tail -1)
    [[ -n "$charm_file" ]] || die "No .charm file found for '$charm' in $charm_dir. Run with --mode build-only or build-and-publish first."

    log "[$charm] Uploading $charm_file ..."
    upload_out=$(cd "$charm_dir" && charmcraft upload --format json "$charm_file")
    revision=$(python3 -c "import sys, json; print(json.load(sys.stdin)['revision'])" <<< "$upload_out")
    log "[$charm] Uploaded as revision $revision"

    log "[$charm] Releasing revision $revision to $CHANNEL ..."
    log "[$charm] NOTE: this keeps whichever resource revisions were last released for this charm/channel."
    log "[$charm]       If you rebuilt an OCI image, upload it first (charmcraft upload-resource ...) and"
    log "[$charm]       re-run with an explicit 'charmcraft release ... --resource=name:rev' yourself instead."
    charmcraft release "$charm" --revision "$revision" --channel "$CHANNEL"
    log "[$charm] Released to $CHANNEL"
done

echo
log "Done. Mode: $MODE | Channel: $CHANNEL"
