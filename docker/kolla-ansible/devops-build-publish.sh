#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O kolla-ansible container images.
# All containers are platform-specific (rocky or ubuntu).
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
# Environment variables (required):
#   RPM_REPO_URL   Trilio RPM repo baseurl  (rocky builds)
#   DEB_REPO_URL   Trilio APT repo line     (ubuntu builds)
#   PIP_REPO_URL   Trilio pip index URL     (horizon-plugin on both platforms)
#
# Examples:
#   RPM_REPO_URL='https://...' PIP_REPO_URL='https://...' bash devops-build-publish.sh 5.2.7-2025.1 rocky
#   DEB_REPO_URL='deb https://...' PIP_REPO_URL='https://...' bash devops-build-publish.sh 5.2.7-2025.1 ubuntu
#   RPM_REPO_URL='https://...' PIP_REPO_URL='https://...' bash devops-build-publish.sh 5.2.7-2025.1 rocky trilio-datamover
#
# Published image format:
#   docker.io/trilio/kolla-<platform>-<container>:<tag>
#   e.g. docker.io/trilio/kolla-rocky-trilio-datamover:5.2.7-2025.1
#        docker.io/trilio/kolla-ubuntu-trilio-datamover:5.2.7-2025.1
#        docker.io/trilio/kolla-rocky-trilio-dms:5.2.7-2025.1
#        docker.io/trilio/kolla-ubuntu-trilio-dms:5.2.7-2025.1

set -e

usage() {
    cat <<EOF
Usage: $0 <tag> <os_platform> [container]

  tag          Docker image tag (any format), e.g. 5.2.7-2025.1
  os_platform  OS platform to build for: rocky | ubuntu
  container    (optional) Build and publish a single container.
               If omitted, all 5 containers are built.

Containers:
  trilio-datamover        Compute node datamover
  trilio-datamover-api    Control plane datamover API
  trilio-horizon-plugin   OpenStack Horizon UI plugin
  trilio-wlm              Workload Manager
  trilio-dms              Dynamic Mount Service

Published image format:
  docker.io/trilio/kolla-<platform>-<container>:<tag>

Examples:
  $0 5.2.7-2025.1 rocky
  $0 5.2.7-2025.1 ubuntu
  $0 5.2.7-2025.1 rocky trilio-datamover
  $0 5.2.7-2025.1 rocky trilio-dms

Options:
  -h, --help   Show this help message and exit.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    usage
    exit 1
fi

TAG="$1"
PLATFORM="$2"
SINGLE_CONTAINER="${3:-}"
OPENSTACK_RELEASE="2025.1"

case "$PLATFORM" in
    rocky|ubuntu) ;;
    *)
        echo "ERROR: Unsupported os_platform '$PLATFORM'. Use rocky or ubuntu."
        exit 1
        ;;
esac

# Repo URLs must be supplied via environment variables — read from the
# "Latest Build Details" Confluence page for the matching T4O release.
if [ "$PLATFORM" = "rocky" ] && [ -z "${RPM_REPO_URL:-}" ]; then
    echo "ERROR: RPM_REPO_URL env var is required for rocky builds."
    exit 1
fi
if [ "$PLATFORM" = "ubuntu" ] && [ -z "${DEB_REPO_URL:-}" ]; then
    echo "ERROR: DEB_REPO_URL env var is required for ubuntu builds."
    exit 1
fi
if [ -z "${PIP_REPO_URL:-}" ]; then
    echo "ERROR: PIP_REPO_URL env var is required (used for horizon-plugin)."
    exit 1
fi

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

    # Substitute repo URL placeholders
    if [ "$PLATFORM" = "rocky" ] && [ -f "$CONT_BUILD_DIR/trilio.repo" ]; then
        sed -i "s|{RPM_REPO_URL}|${RPM_REPO_URL}|g" "$CONT_BUILD_DIR/trilio.repo"
    fi
    if [ "$PLATFORM" = "ubuntu" ] && [ -f "$CONT_BUILD_DIR/trilio.list" ]; then
        sed -i "s|{DEB_REPO_URL}|${DEB_REPO_URL}|g" "$CONT_BUILD_DIR/trilio.list"
    fi

    BUILD_ARGS="--build-arg TRILIO_PIP_INDEX_URL=${PIP_REPO_URL}"

    docker build --no-cache --pull --network host $BUILD_ARGS -t "$IMAGE" "$CONT_BUILD_DIR"
    docker push "$IMAGE"

    echo " Published : $IMAGE"
done

# Build trilio-dms — platform-specific (Dockerfile_rocky / Dockerfile_ubuntu)
if [ -z "$SINGLE_CONTAINER" ] || [ "$SINGLE_CONTAINER" = "trilio-dms" ]; then

    DMS_SOURCE_DF="$BASE_DIR/trilio-dms/Dockerfile_${PLATFORM}"
    DMS_IMAGE="docker.io/trilio/kolla-${PLATFORM}-trilio-dms:${TAG}"

    if [ ! -f "$DMS_SOURCE_DF" ]; then
        echo ""
        echo "SKIP: trilio-dms — $(basename "$DMS_SOURCE_DF") not found"
    else
        echo ""
        echo "--------------------------------------------------"
        echo " Building : $DMS_IMAGE"
        echo "--------------------------------------------------"

        DMS_BUILD_DIR="$BUILD_DIR/trilio-dms"
        cp -R "$BASE_DIR/trilio-dms" "$DMS_BUILD_DIR"
        cp "$DMS_SOURCE_DF" "$DMS_BUILD_DIR/Dockerfile"
        rm -f "$DMS_BUILD_DIR/Dockerfile_"*

        if [ "$PLATFORM" = "rocky" ] && [ -f "$DMS_BUILD_DIR/trilio.repo" ]; then
            sed -i "s|{RPM_REPO_URL}|${RPM_REPO_URL}|g" "$DMS_BUILD_DIR/trilio.repo"
        fi
        if [ "$PLATFORM" = "ubuntu" ] && [ -f "$DMS_BUILD_DIR/trilio.list" ]; then
            sed -i "s|{DEB_REPO_URL}|${DEB_REPO_URL}|g" "$DMS_BUILD_DIR/trilio.list"
        fi

        docker build --no-cache --pull --network host -t "$DMS_IMAGE" "$DMS_BUILD_DIR"
        docker push "$DMS_IMAGE"

        echo " Published : $DMS_IMAGE"
    fi
fi

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
