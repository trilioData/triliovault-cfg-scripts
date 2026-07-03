#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O Sunbeam Canonical container images to DockerHub.
# Ubuntu-only — no OS platform argument required.
#
# Usage:
#   bash devops-build-publish.sh <tag> [container[,container,...]]
#
# Arguments:
#   tag          Docker image tag (any format), e.g. 6.2.1-2024.1
#   container    (optional) Comma-separated list of containers to build.
#                  trilio-datamover | trilio-datamover-api |
#                  trilio-horizon-plugin | trilio-wlm | trilio-dms
#                If omitted, all 5 containers are built.
#
# Examples:
#   bash devops-build-publish.sh 6.2.1-2024.1
#   bash devops-build-publish.sh 6.2.1-2024.1 trilio-wlm
#   bash devops-build-publish.sh 6.2.1-2024.1 trilio-wlm,trilio-datamover-api
#   bash devops-build-publish.sh 6.2.1-2024.1 trilio-wlm,trilio-datamover-api,trilio-dms
#
# Published image format:
#   docker.io/trilio/<container>-canonical:<tag>
#   e.g. docker.io/trilio/trilio-wlm-canonical:6.2.1-2024.1
#        docker.io/trilio/trilio-datamover-canonical:6.2.1-2024.1
#        docker.io/trilio/trilio-datamover-api-canonical:6.2.1-2024.1
#        docker.io/trilio/trilio-horizon-plugin-canonical:6.2.1-2024.1
#        docker.io/trilio/trilio-dms-canonical:6.2.1-2024.1

set -e

usage() {
    cat <<EOF
Usage: $0 <tag> [container[,container,...]]

  tag          Docker image tag (any format), e.g. 6.2.1-2024.1
  container    (optional) Comma-separated list of containers to build.
               If omitted, all 5 containers are built.

Containers:
  trilio-datamover        Compute node datamover (not used as a container in Sunbeam — included for image distribution)
  trilio-datamover-api    Control plane datamover API
  trilio-horizon-plugin   OpenStack Horizon UI plugin
  trilio-wlm              Workload Manager
  trilio-dms              Dynamic Mount Service

Published image format:
  docker.io/trilio/<container>-canonical:<tag>

Examples:
  $0 6.2.1-2024.1
  $0 6.2.1-2024.1 trilio-wlm
  $0 6.2.1-2024.1 trilio-wlm,trilio-datamover-api
  $0 6.2.1-2024.1 trilio-wlm,trilio-datamover-api,trilio-dms

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

TAG="$1"
OPENSTACK_RELEASE="2024.1"
TRILIO_PIP_INDEX_URL="https://pypi.fury.io/trilio-6-2/"

ALL_CONTAINERS=(trilio-datamover trilio-datamover-api trilio-horizon-plugin trilio-wlm trilio-dms)

# Parse comma-separated container list from second argument
SELECTED_CONTAINERS=()
if [ -n "${2:-}" ]; then
    IFS=',' read -ra SELECTED_CONTAINERS <<< "$2"
    for c in "${SELECTED_CONTAINERS[@]}"; do
        valid=0
        for a in "${ALL_CONTAINERS[@]}"; do
            [ "$c" = "$a" ] && valid=1 && break
        done
        if [ $valid -eq 0 ]; then
            echo "ERROR: Unknown container '$c'."
            echo "Valid options: ${ALL_CONTAINERS[*]}"
            exit 1
        fi
    done
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=================================================="
echo " T4O Sunbeam Canonical Build & Publish"
echo " Tag              : $TAG"
echo " OpenStack release: $OPENSTACK_RELEASE"
if [ ${#SELECTED_CONTAINERS[@]} -gt 0 ]; then
echo " Container        : $(IFS=','; echo "${SELECTED_CONTAINERS[*]}")"
else
echo " Container        : all"
fi
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${TAG}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

for CONTAINER in "${ALL_CONTAINERS[@]}"; do

    if [ ${#SELECTED_CONTAINERS[@]} -gt 0 ]; then
        found=0
        for s in "${SELECTED_CONTAINERS[@]}"; do
            [ "$s" = "$CONTAINER" ] && found=1 && break
        done
        [ $found -eq 0 ] && continue
    fi

    SOURCE_DF="$BASE_DIR/$CONTAINER/Dockerfile_${OPENSTACK_RELEASE}"

    if [ ! -f "$SOURCE_DF" ]; then
        echo ""
        echo "SKIP: $CONTAINER — $(basename "$SOURCE_DF") not found"
        continue
    fi

    IMAGE="docker.io/trilio/${CONTAINER}-canonical:${TAG}"

    echo ""
    echo "--------------------------------------------------"
    echo " Building : $IMAGE"
    echo "--------------------------------------------------"

    CONT_BUILD_DIR="$BUILD_DIR/$CONTAINER"
    cp -R "$BASE_DIR/$CONTAINER" "$CONT_BUILD_DIR"
    cp "$SOURCE_DF" "$CONT_BUILD_DIR/Dockerfile"
    rm -f "$CONT_BUILD_DIR/Dockerfile_"*

    BUILD_ARGS=""
    if [ "$CONTAINER" = "trilio-horizon-plugin" ]; then
        BUILD_ARGS="--build-arg TRILIO_PIP_INDEX_URL=${TRILIO_PIP_INDEX_URL}"
    fi

    docker build --no-cache --pull --network host $BUILD_ARGS -t "$IMAGE" "$CONT_BUILD_DIR"
    docker push "$IMAGE"

    echo " Published : $IMAGE"
done

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
