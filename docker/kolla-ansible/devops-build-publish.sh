#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O kolla-ansible container images.
#
# Usage:
#   bash devops-build-publish.sh <tag>
#
# Arguments:
#   tag   Docker image tag (any format), e.g. 5.2.7-2025.1, shyam-tv7315-1
#
# Examples:
#   bash devops-build-publish.sh 5.2.7-2025.1
#   bash devops-build-publish.sh shyam-tv7315-1
#
# Published image format:
#   docker.io/trilio/kolla-<container>:<tag>
#   e.g. docker.io/trilio/kolla-trilio-datamover:5.2.7-2025.1

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <tag>"
    echo ""
    echo "  tag   Docker image tag (any format), e.g. 5.2.7-2025.1"
    echo ""
    echo "Example:"
    echo "  $0 5.2.7-2025.1"
    exit 1
fi

TAG="$1"
OPENSTACK_RELEASE="2025.1"
PLATFORM="rocky"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

declare -a CONTAINERS=(
    trilio-datamover
    trilio-datamover-api
    trilio-horizon-plugin
    trilio-wlm
    trilio-dms
)

echo "=================================================="
echo " T4O Kolla-Ansible Build & Publish"
echo " Tag              : $TAG"
echo " OpenStack release: $OPENSTACK_RELEASE"
echo " Platform         : $PLATFORM"
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${TAG}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

for CONTAINER in "${CONTAINERS[@]}"; do

    # trilio-dms has a single Dockerfile; all others are versioned per release and platform
    if [ "$CONTAINER" = "trilio-dms" ]; then
        SOURCE_DF="$BASE_DIR/$CONTAINER/Dockerfile"
    else
        SOURCE_DF="$BASE_DIR/$CONTAINER/Dockerfile_${OPENSTACK_RELEASE}_${PLATFORM}"
    fi

    if [ ! -f "$SOURCE_DF" ]; then
        echo ""
        echo "SKIP: $CONTAINER — $(basename "$SOURCE_DF") not found"
        continue
    fi

    IMAGE="docker.io/trilio/kolla-${CONTAINER}:${TAG}"

    echo ""
    echo "--------------------------------------------------"
    echo " Building : $IMAGE"
    echo "--------------------------------------------------"

    CONT_BUILD_DIR="$BUILD_DIR/$CONTAINER"
    cp -R "$BASE_DIR/$CONTAINER" "$CONT_BUILD_DIR"

    # For versioned containers, activate the versioned Dockerfile and remove the rest
    if [ "$CONTAINER" != "trilio-dms" ]; then
        cp "$SOURCE_DF" "$CONT_BUILD_DIR/Dockerfile"
        rm -f "$CONT_BUILD_DIR/Dockerfile_"*
    fi

    docker build --no-cache --pull -t "$IMAGE" "$CONT_BUILD_DIR"
    docker push "$IMAGE"

    echo " Published : $IMAGE"
done

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
