#!/bin/bash
# devops-build-publish.sh
#
# Builds and/or publishes T4O Sunbeam Canonical container images to Docker Hub.
# Ubuntu-only — no OS platform argument required.
#
# Usage:
#   bash devops-build-publish.sh --tag <TAG> --containers <all|container[,...]> --mode <MODE>
#                                [--openstack-release <RELEASE>] [--apt-url <URL>] [--pip-url <URL>]
#
# Options:
#   --tag               Docker image tag, e.g. 6.2.1-2024.1
#   --containers        'all' or comma-separated container names
#   --mode              build-only        Build images locally; do not push to Docker Hub
#                       publish-only      Push locally-built images; skip build
#                       build-and-publish Build and push images
#   --openstack-release Override the OpenStack release derived from --tag (for dev tags)
#                       e.g. --openstack-release 2024.1
#   --apt-url           Override the APT repo URL substituted into trilio.list (for dev tags)
#                       e.g. --apt-url "deb [trusted=yes] https://apt.fury.io/trilio-maint-6-2 /"
#   --pip-url           Override the PyPI index URL for horizon plugin pip packages (for dev tags)
#                       e.g. --pip-url "https://pypi.fury.io/trilio-6-2/"
#
# Containers:
#   trilio-datamover-api    Control plane DataMover API
#   trilio-horizon-plugin   OpenStack Horizon UI plugin
#   trilio-wlm              WorkloadManager (also used as DMS sidecar image)
#
# Note: trilio-datamover is NOT included — the DataMover is installed via APT
#       packages by the trilio-data-mover-sunbeam machine subordinate charm
#       on compute nodes. No OCI image is needed.
#
# Published image format:
#   docker.io/trilio/<container>-canonical:<tag>
#   e.g. docker.io/trilio/trilio-wlm-canonical:6.2.1-2024.1
#
# Release build examples:
#   bash devops-build-publish.sh --tag 6.2.1-2024.1 --containers all --mode build-and-publish
#   bash devops-build-publish.sh --tag 6.2.1-2024.1 --containers trilio-wlm --mode build-only
#   bash devops-build-publish.sh --tag 6.2.1-2024.1 --containers all --mode publish-only
#
# Dev build example (custom tag that does not follow <version>-<os-release> format):
#   bash devops-build-publish.sh --tag shyam-tv7404-11 \
#       --openstack-release 2024.1 \
#       --apt-url "deb [trusted=yes] https://apt.fury.io/trilio-maint-6-2 /" \
#       --pip-url "https://pypi.fury.io/trilio-6-2/" \
#       --containers all --mode build-and-publish

set -e

# OPENSTACK_RELEASE, APT_REPO_URL, and TRILIO_PIP_INDEX_URL are derived from
# --tag after arg parsing. Optional overrides are provided via --openstack-release
# and --apt-url for dev builds where the tag doesn't follow <version>-<os-release>.
OPENSTACK_RELEASE=""
APT_REPO_URL=""
TRILIO_PIP_INDEX_URL=""
ALL_CONTAINERS=(trilio-datamover-api trilio-horizon-plugin trilio-wlm)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 --tag <TAG> --containers <all|container[,...]> --mode <MODE>
          [--openstack-release <RELEASE>] [--apt-url <URL>]

  --tag               Docker image tag, e.g. 6.2.1-2024.1
  --containers        'all' or comma-separated container names
  --mode              build-only        Build images locally; do not push
                      publish-only      Push locally-built images; skip build
                      build-and-publish Build and push images
  --openstack-release Override OpenStack release derived from --tag (for dev tags)
  --apt-url           Override APT repo URL substituted into trilio.list (for dev tags)
  --pip-url           Override PyPI index URL for horizon plugin pip packages (for dev tags)

Containers:
  trilio-datamover-api    Control plane DataMover API
  trilio-horizon-plugin   OpenStack Horizon UI plugin
  trilio-wlm              WorkloadManager (also serves as DMS sidecar image)

Note: trilio-datamover is NOT built here. The DataMover is installed directly
via APT packages by the trilio-data-mover-sunbeam machine charm on compute nodes.

Published image format:
  docker.io/trilio/<container>-canonical:<tag>

Release build examples:
  $0 --tag 6.2.1-2024.1 --containers all --mode build-and-publish
  $0 --tag 6.2.1-2024.1 --containers trilio-wlm,trilio-dms --mode build-only

Dev build example (tag does not follow <version>-<os-release> format):
  $0 --tag shyam-tv7404-11 \\
      --openstack-release 2024.1 \\
      --apt-url "deb [trusted=yes] https://apt.fury.io/trilio-maint-6-2 /" \\
      --pip-url "https://pypi.fury.io/trilio-6-2/" \\
      --containers all --mode build-and-publish

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
CONTAINERS_ARG=""
MODE=""
OPENSTACK_RELEASE_OVERRIDE=""
APT_URL_OVERRIDE=""
PIP_URL_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --tag)
            [ -n "${2:-}" ] || { echo "ERROR: --tag requires a value" >&2; exit 1; }
            TAG="$2"; shift 2 ;;
        --containers)
            [ -n "${2:-}" ] || { echo "ERROR: --containers requires a value" >&2; exit 1; }
            CONTAINERS_ARG="$2"; shift 2 ;;
        --mode)
            [ -n "${2:-}" ] || { echo "ERROR: --mode requires a value" >&2; exit 1; }
            MODE="$2"; shift 2 ;;
        --openstack-release)
            [ -n "${2:-}" ] || { echo "ERROR: --openstack-release requires a value" >&2; exit 1; }
            OPENSTACK_RELEASE_OVERRIDE="$2"; shift 2 ;;
        --apt-url)
            [ -n "${2:-}" ] || { echo "ERROR: --apt-url requires a value" >&2; exit 1; }
            APT_URL_OVERRIDE="$2"; shift 2 ;;
        --pip-url)
            [ -n "${2:-}" ] || { echo "ERROR: --pip-url requires a value" >&2; exit 1; }
            PIP_URL_OVERRIDE="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$TAG" ]            || { echo "ERROR: --tag is required" >&2; usage >&2; exit 1; }
[ -n "$CONTAINERS_ARG" ] || { echo "ERROR: --containers is required ('all' or comma-separated container names)" >&2; usage >&2; exit 1; }
[ -n "$MODE" ]           || { echo "ERROR: --mode is required" >&2; usage >&2; exit 1; }

# Derive OPENSTACK_RELEASE and PyPI index from the tag (format: <version>-<os-release>).
# Example: 6.2.1-2024.1 → OPENSTACK_RELEASE=2024.1, TRILIO_MAJOR_MINOR=6.2
TRILIO_VERSION_FULL="${TAG%%-*}"                        # e.g. 6.2.1
OPENSTACK_RELEASE="${TAG#*-}"                           # e.g. 2024.1
TRILIO_MAJOR_MINOR="${TRILIO_VERSION_FULL%.*}"          # e.g. 6.2
TRILIO_PIP_MAJOR_MINOR="${TRILIO_MAJOR_MINOR//./-}"    # e.g. 6-2
TRILIO_PIP_INDEX_URL="https://pypi.fury.io/trilio-${TRILIO_PIP_MAJOR_MINOR}/"

# Apply optional overrides (used for dev builds with non-standard tag formats)
[ -n "$OPENSTACK_RELEASE_OVERRIDE" ] && OPENSTACK_RELEASE="$OPENSTACK_RELEASE_OVERRIDE"
APT_REPO_URL="${APT_URL_OVERRIDE:-deb [trusted=yes] https://apt.fury.io/trilio-maint-${TRILIO_PIP_MAJOR_MINOR} /}"
[ -n "$PIP_URL_OVERRIDE" ] && TRILIO_PIP_INDEX_URL="$PIP_URL_OVERRIDE"

case "$MODE" in
    build-only|publish-only|build-and-publish) ;;
    *) echo "ERROR: Invalid --mode '$MODE'. Use: build-only | publish-only | build-and-publish" >&2; exit 1 ;;
esac

# Expand 'all' or validate comma-separated names
SELECTED_CONTAINERS=()
if [ "$CONTAINERS_ARG" = "all" ]; then
    SELECTED_CONTAINERS=("${ALL_CONTAINERS[@]}")
else
    IFS=',' read -ra SELECTED_CONTAINERS <<< "$CONTAINERS_ARG"
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
echo " APT repo   : $APT_REPO_URL"
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

        # Substitute the {DEB_REPO_URL} placeholder in trilio.list with the real APT source line
        TRILIO_LIST="$CONT_BUILD_DIR/trilio.list"
        if [ -f "$TRILIO_LIST" ]; then
            sed -i "s|{DEB_REPO_URL}|${APT_REPO_URL}|g" "$TRILIO_LIST"
        fi

        BUILD_ARGS=()
        if [ "$CONTAINER" = "trilio-horizon-plugin" ]; then
            BUILD_ARGS=(--build-arg "TRILIO_PIP_INDEX_URL=${TRILIO_PIP_INDEX_URL}")
        fi

        docker build --no-cache --pull --network host "${BUILD_ARGS[@]}" -t "$IMAGE" "$CONT_BUILD_DIR"
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
