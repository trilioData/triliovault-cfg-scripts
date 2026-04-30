#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O kolla-ansible container images.
# OS-specific containers are built for the given platform.
# trilio-dms is a common image built regardless of platform.
#
# Usage:
#   bash devops-build-publish.sh <tag> <os_platform> [container]
#
# Arguments:
#   tag          Docker image tag (any format), e.g. 5.2.7-2025.1
#   os_platform  OS platform: rocky | ubuntu
#   container    (optional) Build only this container:
#                  trilio-datamover | trilio-datamover-api |
#                  trilio-horizon-plugin | trilio-wlm | trilio-dms
#                If omitted, all 5 containers are built.
#
# Examples:
#   bash devops-build-publish.sh 5.2.7-2025.1 rocky
#   bash devops-build-publish.sh 5.2.7-2025.1 ubuntu
#   bash devops-build-publish.sh 5.2.7-2025.1 rocky trilio-datamover
#   bash devops-build-publish.sh 5.2.7-2025.1 rocky trilio-dms
#
# Published image format:
#   docker.io/trilio/kolla-<platform>-<container>:<tag>
#   docker.io/trilio/kolla-trilio-dms:<tag>   (common, no platform)
#   e.g. docker.io/trilio/kolla-rocky-trilio-datamover:5.2.7-2025.1
#        docker.io/trilio/kolla-ubuntu-trilio-datamover:5.2.7-2025.1
#        docker.io/trilio/kolla-trilio-dms:5.2.7-2025.1

set -e

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <tag> <os_platform> [container]"
    echo ""
    echo "  tag          Docker image tag (any format), e.g. 5.2.7-2025.1"
    echo "  os_platform  rocky | ubuntu"
    echo "  container    (optional) trilio-datamover | trilio-datamover-api |"
    echo "                          trilio-horizon-plugin | trilio-wlm | trilio-dms"
    echo ""
    echo "Examples:"
    echo "  $0 5.2.7-2025.1 rocky"
    echo "  $0 5.2.7-2025.1 rocky trilio-datamover"
    echo "  $0 5.2.7-2025.1 rocky trilio-dms"
    exit 1
fi

TAG="$1"
PLATFORM="$2"
SINGLE_CONTAINER="${3:-}"
OPENSTACK_RELEASE="2025.1"
TRILIO_PIP_INDEX_URL="https://pypi.fury.io/trilio-6-1/"

case "$PLATFORM" in
    rocky|ubuntu) ;;
    *)
        echo "ERROR: Unsupported os_platform '$PLATFORM'. Use rocky or ubuntu."
        exit 1
        ;;
esac

ALL_CONTAINERS=(trilio-datamover trilio-datamover-api trilio-horizon-plugin trilio-wlm trilio-dms)
if [ -n "$SINGLE_CONTAINER" ]; then
    valid=0
    for c in "${ALL_CONTAINERS[@]}"; do
        [ "$c" = "$SINGLE_CONTAINER" ] && valid=1 && break
    done
    if [ $valid -eq 0 ]; then
        echo "ERROR: Unknown container '$SINGLE_CONTAINER'."
        echo "Valid options: ${ALL_CONTAINERS[*]}"
        exit 1
    fi
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=================================================="
echo " T4O Kolla-Ansible Build & Publish"
echo " Tag              : $TAG"
echo " OpenStack release: $OPENSTACK_RELEASE"
echo " Platform         : $PLATFORM"
if [ -n "$SINGLE_CONTAINER" ]; then
echo " Container        : $SINGLE_CONTAINER (single)"
else
echo " Container        : all"
fi
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${TAG}_${PLATFORM}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Build OS-specific containers
declare -a OS_CONTAINERS=(
    trilio-datamover
    trilio-datamover-api
    trilio-horizon-plugin
    trilio-wlm
)

for CONTAINER in "${OS_CONTAINERS[@]}"; do

    if [ -n "$SINGLE_CONTAINER" ] && [ "$SINGLE_CONTAINER" != "$CONTAINER" ]; then
        continue
    fi

    SOURCE_DF="$BASE_DIR/$CONTAINER/Dockerfile_${OPENSTACK_RELEASE}_${PLATFORM}"

    if [ ! -f "$SOURCE_DF" ]; then
        echo ""
        echo "SKIP: $CONTAINER — $(basename "$SOURCE_DF") not found"
        continue
    fi

    IMAGE="docker.io/trilio/kolla-${PLATFORM}-${CONTAINER}:${TAG}"

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

# Build trilio-dms — common image, not OS-specific
if [ -z "$SINGLE_CONTAINER" ] || [ "$SINGLE_CONTAINER" = "trilio-dms" ]; then

    DMS_SOURCE_DF="$BASE_DIR/trilio-dms/Dockerfile"
    DMS_IMAGE="docker.io/trilio/kolla-trilio-dms:${TAG}"

    echo ""
    echo "--------------------------------------------------"
    echo " Building : $DMS_IMAGE  (common image)"
    echo "--------------------------------------------------"

    DMS_BUILD_DIR="$BUILD_DIR/trilio-dms"
    cp -R "$BASE_DIR/trilio-dms" "$DMS_BUILD_DIR"

    docker build --no-cache --pull --network host -t "$DMS_IMAGE" "$DMS_BUILD_DIR"
    docker push "$DMS_IMAGE"

    echo " Published : $DMS_IMAGE"
fi

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
