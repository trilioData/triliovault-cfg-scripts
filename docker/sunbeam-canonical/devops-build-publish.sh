#!/bin/bash
# devops-build-publish.sh
#
# Builds and/or publishes T4O Sunbeam Canonical container images to Docker Hub.
# Ubuntu-only — no OS platform argument required.
#
# Usage:
#   bash devops-build-publish.sh <tag> <all|container[,container,...]> --mode <MODE>
#
# Arguments:
#   tag        Docker image tag, e.g. 6.2.1-2024.1
#   targets    'all'  — build/publish every container
#              comma-separated names — build/publish only those containers
#   --mode     build-only        Build images locally; do not push to Docker Hub
#              publish-only      Push locally-built images; skip build
#              build-and-publish Build and push images
#
# Containers:
#   trilio-datamover-api    Control plane DataMover API
#   trilio-horizon-plugin   OpenStack Horizon UI plugin
#   trilio-wlm              WorkloadManager
#   trilio-dms              Dynamic Mount Service (release-independent; uses plain Dockerfile)
#
# Note: trilio-datamover is NOT included — the DataMover is installed via APT
#       packages by the trilio-data-mover-sunbeam machine subordinate charm
#       on compute nodes. No OCI image is needed.
#
# Published image format:
#   docker.io/trilio/<container>-canonical:<tag>
#   e.g. docker.io/trilio/trilio-wlm-canonical:6.2.1-2024.1
#
# Examples:
#   bash devops-build-publish.sh 6.2.1-2024.1 all --mode build-and-publish
#   bash devops-build-publish.sh 6.2.1-2024.1 trilio-wlm,trilio-dms --mode build-only
#   bash devops-build-publish.sh 6.2.1-2024.1 all --mode publish-only

set -e

OPENSTACK_RELEASE="2024.1"
TRILIO_PIP_INDEX_URL="https://pypi.fury.io/trilio-6-2/"
ALL_CONTAINERS=(trilio-datamover-api trilio-horizon-plugin trilio-wlm trilio-dms)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 <tag> <all|container[,container,...]> --mode <MODE>

  tag        Docker image tag, e.g. 6.2.1-2024.1
  targets    'all' or comma-separated container names
  --mode     build-only        Build images locally; do not push
             publish-only      Push locally-built images; skip build
             build-and-publish Build and push images

Containers:
  trilio-datamover-api    Control plane DataMover API
  trilio-horizon-plugin   OpenStack Horizon UI plugin
  trilio-wlm              WorkloadManager
  trilio-dms              Dynamic Mount Service (release-independent; plain Dockerfile)

Note: trilio-datamover is NOT built here. The DataMover is installed directly
via APT packages by the trilio-data-mover-sunbeam machine charm on compute nodes.

Published image format:
  docker.io/trilio/<container>-canonical:<tag>

Examples:
  $0 6.2.1-2024.1 all --mode build-and-publish
  $0 6.2.1-2024.1 trilio-wlm,trilio-dms --mode build-only
  $0 6.2.1-2024.1 all --mode publish-only

Options:
  -h, --help   Show this help message and exit.
EOF
}

check_docker_login() {
    local registry="https://index.docker.io/v1/"
    local config="${HOME}/.docker/config.json"

    if [ ! -f "$config" ]; then
        echo "ERROR: Docker Hub not configured. Run: docker login docker.io" >&2
        exit 1
    fi

    # Resolve credential backend: per-registry helper > global store > inline auth.
    local helper
    helper=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
r = sys.argv[2]
print(d.get('credHelpers', {}).get(r) or d.get('credsStore') or '')
" "$config" "$registry" 2>/dev/null || true)

    if [ -n "$helper" ]; then
        if ! echo "$registry" | "docker-credential-${helper}" get > /dev/null 2>&1; then
            echo "ERROR: Not logged in to Docker Hub. Run: docker login docker.io" >&2
            exit 1
        fi
    else
        if ! python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
auth = d.get('auths', {}).get(sys.argv[2], {}).get('auth', '')
sys.exit(0 if auth else 1)
" "$config" "$registry" 2>/dev/null; then
            echo "ERROR: Not logged in to Docker Hub. Run: docker login docker.io" >&2
            exit 1
        fi
    fi

    echo "Docker Hub login: OK"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

TAG=""
TARGETS_ARG=""
MODE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --mode)
            [ -n "${2:-}" ] || { echo "ERROR: --mode requires a value" >&2; exit 1; }
            MODE="$2"; shift 2 ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [ -z "$TAG" ]; then
                TAG="$1"
            elif [ -z "$TARGETS_ARG" ]; then
                TARGETS_ARG="$1"
            else
                echo "ERROR: Unexpected argument: $1" >&2; usage >&2; exit 1
            fi
            shift ;;
    esac
done

[ -n "$TAG" ]         || { echo "ERROR: <tag> is required" >&2; usage >&2; exit 1; }
[ -n "$TARGETS_ARG" ] || { echo "ERROR: <targets> is required ('all' or comma-separated container names)" >&2; usage >&2; exit 1; }
[ -n "$MODE" ]        || { echo "ERROR: --mode is required" >&2; usage >&2; exit 1; }

case "$MODE" in
    build-only|publish-only|build-and-publish) ;;
    *) echo "ERROR: Invalid --mode '$MODE'. Use: build-only | publish-only | build-and-publish" >&2; exit 1 ;;
esac

# Expand 'all' or validate comma-separated names
SELECTED_CONTAINERS=()
if [ "$TARGETS_ARG" = "all" ]; then
    SELECTED_CONTAINERS=("${ALL_CONTAINERS[@]}")
else
    IFS=',' read -ra SELECTED_CONTAINERS <<< "$TARGETS_ARG"
    for c in "${SELECTED_CONTAINERS[@]}"; do
        valid=0
        for a in "${ALL_CONTAINERS[@]}"; do
            [ "$c" = "$a" ] && valid=1 && break
        done
        if [ $valid -eq 0 ]; then
            echo "ERROR: Unknown container '$c'. Valid: ${ALL_CONTAINERS[*]}" >&2
            exit 1
        fi
    done
fi

# Pre-flight: Docker Hub login only needed when pushing
if [ "$MODE" != "build-only" ]; then
    check_docker_login
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=================================================="
echo " T4O Sunbeam Canonical Build & Publish"
echo " Tag        : $TAG"
echo " OS Release : $OPENSTACK_RELEASE"
echo " Containers : ${SELECTED_CONTAINERS[*]}"
echo " Mode       : $MODE"
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${TAG}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

for CONTAINER in "${SELECTED_CONTAINERS[@]}"; do

    IMAGE="docker.io/trilio/${CONTAINER}-canonical:${TAG}"

    echo ""
    echo "--------------------------------------------------"
    echo " Container : $CONTAINER"
    echo " Image     : $IMAGE"
    echo "--------------------------------------------------"

    # --- Build ---
    if [ "$MODE" != "publish-only" ]; then
        # Prefer release-specific Dockerfile; fall back to generic Dockerfile.
        # (trilio-dms is release-independent and ships a plain Dockerfile)
        RELEASE_DF="$BASE_DIR/$CONTAINER/Dockerfile_${OPENSTACK_RELEASE}"
        GENERIC_DF="$BASE_DIR/$CONTAINER/Dockerfile"

        if [ -f "$RELEASE_DF" ]; then
            SOURCE_DF="$RELEASE_DF"
        elif [ -f "$GENERIC_DF" ]; then
            SOURCE_DF="$GENERIC_DF"
        else
            echo "SKIP: $CONTAINER — no Dockerfile found (tried Dockerfile_${OPENSTACK_RELEASE} and Dockerfile)" >&2
            continue
        fi

        CONT_BUILD_DIR="$BUILD_DIR/$CONTAINER"
        cp -R "$BASE_DIR/$CONTAINER" "$CONT_BUILD_DIR"
        if [ "$(basename "$SOURCE_DF")" != "Dockerfile" ]; then
            cp "$SOURCE_DF" "$CONT_BUILD_DIR/Dockerfile"
        fi
        rm -f "$CONT_BUILD_DIR/Dockerfile_"*

        BUILD_ARGS=""
        if [ "$CONTAINER" = "trilio-horizon-plugin" ]; then
            BUILD_ARGS="--build-arg TRILIO_PIP_INDEX_URL=${TRILIO_PIP_INDEX_URL}"
        fi

        docker build --no-cache --pull --network host $BUILD_ARGS -t "$IMAGE" "$CONT_BUILD_DIR"
        echo " Built    : $IMAGE"
    fi

    # --- Publish ---
    if [ "$MODE" != "build-only" ]; then
        if [ "$MODE" = "publish-only" ] && ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
            echo "ERROR: Image '$IMAGE' not found locally. Run with --mode build-only or build-and-publish first." >&2
            exit 1
        fi
        docker push "$IMAGE"
        echo " Published: $IMAGE"
    fi

done

echo ""
echo "=================================================="
echo " Done. Mode: $MODE"
echo "=================================================="
