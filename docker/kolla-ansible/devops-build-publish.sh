#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O kolla-ansible container images for a given OS.
# Combines build and push in a single run. Does not modify existing scripts.
#
# Usage:
#   bash devops-build-publish.sh <os> <openstack_release> <tag> <repo_url>
#
# Arguments:
#   os                Target OS: rocky9 | ubuntu
#   openstack_release OpenStack release name, e.g. 2025.1, zed
#   tag               Full Docker image tag, e.g. 5.2.7-2025.1
#   repo_url          Trilio package repo URL injected into trilio.repo (RPM)
#                     or trilio.list (DEB)
#
# Examples:
#   bash devops-build-publish.sh rocky9  2025.1 5.2.7-2025.1 https://repo.example.com/rpm/5.2.7
#   bash devops-build-publish.sh ubuntu  2025.1 5.2.7-2025.1 https://repo.example.com/deb/5.2.7
#
# Published image format:
#   docker.io/trilio/kolla-<platform>-<container>:<tag>
#   e.g. docker.io/trilio/kolla-rocky-trilio-datamover:5.2.7-2025.1

set -e

if [ $# -ne 4 ]; then
    echo "Usage: $0 <os> <openstack_release> <tag> <repo_url>"
    echo ""
    echo "  os                rocky9 | ubuntu"
    echo "  openstack_release e.g. 2025.1, 2024.1, zed"
    echo "  tag               e.g. 5.2.7-2025.1"
    echo "  repo_url          Trilio package repo URL"
    echo ""
    echo "Example:"
    echo "  $0 rocky9 2025.1 5.2.7-2025.1 https://repo.example.com/rpm/5.2.7"
    exit 1
fi

OS="$1"
OPENSTACK_RELEASE="$2"
TAG="$3"
REPO_URL="$4"

# Derive platform from OS (strip trailing digits: rocky9 -> rocky, ubuntu22 -> ubuntu)
PLATFORM=$(echo "$OS" | sed 's/[0-9]*$//')

# Determine repo file type based on platform
case "$PLATFORM" in
    rocky|centos) REPO_TYPE="rpm" ;;
    ubuntu|debian) REPO_TYPE="deb" ;;
    *)
        echo "ERROR: Unsupported OS platform '$PLATFORM' (derived from '$OS')"
        echo "       Supported platforms: rocky*, ubuntu*"
        exit 1
        ;;
esac

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
echo " OS               : $OS  (platform: $PLATFORM)"
echo " OpenStack release: $OPENSTACK_RELEASE"
echo " Tag              : $TAG"
echo " Repo type        : $REPO_TYPE"
echo " Repo URL         : $REPO_URL"
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${OS}_${OPENSTACK_RELEASE}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

for CONTAINER in "${CONTAINERS[@]}"; do

    VERSIONED_DF="$BASE_DIR/$CONTAINER/Dockerfile_${OPENSTACK_RELEASE}_${PLATFORM}"

    if [ ! -f "$VERSIONED_DF" ]; then
        echo ""
        echo "SKIP: $CONTAINER — Dockerfile_${OPENSTACK_RELEASE}_${PLATFORM} not found"
        continue
    fi

    IMAGE="trilio/kolla-${PLATFORM}-${CONTAINER}:${TAG}"

    echo ""
    echo "--------------------------------------------------"
    echo " Building : $IMAGE"
    echo "--------------------------------------------------"

    CONT_BUILD_DIR="$BUILD_DIR/$CONTAINER"
    cp -R "$BASE_DIR/$CONTAINER" "$CONT_BUILD_DIR"

    # Activate the versioned Dockerfile and remove the rest to keep the context clean
    cp "$VERSIONED_DF" "$CONT_BUILD_DIR/Dockerfile"
    rm -f "$CONT_BUILD_DIR/Dockerfile_"*

    # Inject repo URL into the appropriate repo file
    if [ "$REPO_TYPE" = "rpm" ]; then
        sed -i "s|{RPM_REPO_URL}|${REPO_URL}|g" "$CONT_BUILD_DIR/trilio.repo"
    else
        sed -i "s|{DEB_REPO_URL}|${REPO_URL}|g" "$CONT_BUILD_DIR/trilio.list"
    fi

    docker build --no-cache --pull -t "$IMAGE" "$CONT_BUILD_DIR"

    echo ""
    echo " Publishing: docker.io/$IMAGE"
    docker tag "$IMAGE" "docker.io/$IMAGE"
    docker push "docker.io/$IMAGE"

    echo " Published : docker.io/$IMAGE"
done

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
