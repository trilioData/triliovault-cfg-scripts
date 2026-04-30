#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O kolla-ansible container images.
# OS-specific containers are built for the given platform.
# trilio-dms is a common image built regardless of platform.
#
# Usage:
#   bash devops-build-publish.sh <tag> <os_platform>
#
# Arguments:
#   tag          Docker image tag (any format), e.g. 5.2.7-2025.1
#   os_platform  OS platform: rocky | ubuntu
#
# Examples:
#   bash devops-build-publish.sh 5.2.7-2025.1 rocky
#   bash devops-build-publish.sh 5.2.7-2025.1 ubuntu
#
# Published image format:
#   docker.io/trilio/kolla-<platform>-trilio-<container>:<tag>
#   docker.io/trilio/kolla-trilio-dms:<tag>   (common, no platform)
#   e.g. docker.io/trilio/kolla-rocky-trilio-datamover:5.2.7-2025.1
#        docker.io/trilio/kolla-ubuntu-trilio-datamover:5.2.7-2025.1
#        docker.io/trilio/kolla-trilio-dms:5.2.7-2025.1

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <tag> <os_platform>"
    echo ""
    echo "  tag          Docker image tag (any format), e.g. 5.2.7-2025.1"
    echo "  os_platform  rocky | ubuntu"
    echo ""
    echo "Examples:"
    echo "  $0 5.2.7-2025.1 rocky"
    echo "  $0 5.2.7-2025.1 ubuntu"
    exit 1
fi

TAG="$1"
PLATFORM="$2"
OPENSTACK_RELEASE="2025.1"

case "$PLATFORM" in
    rocky|ubuntu) ;;
    *)
        echo "ERROR: Unsupported os_platform '$PLATFORM'. Use rocky or ubuntu."
        exit 1
        ;;
esac

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# OS-specific containers — versioned Dockerfile per release and platform
declare -a OS_CONTAINERS=(
    trilio-datamover
    trilio-datamover-api
    trilio-horizon-plugin
    trilio-wlm
)

echo "=================================================="
echo " T4O Kolla-Ansible Build & Publish"
echo " Tag              : $TAG"
echo " OpenStack release: $OPENSTACK_RELEASE"
echo " Platform         : $PLATFORM"
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${TAG}_${PLATFORM}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Build OS-specific containers
for CONTAINER in "${OS_CONTAINERS[@]}"; do

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

    docker build --no-cache --pull --network host -t "$IMAGE" "$CONT_BUILD_DIR"
    docker push "$IMAGE"

    echo " Published : $IMAGE"
done

# Build trilio-dms — common image, not OS-specific
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

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
