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
#   tag          Docker image tag (any format), e.g. 6.2.0-2025.1
#   os_platform  OS platform: rocky | ubuntu
#   container    (optional) Build only this container:
#                  trilio-datamover | trilio-datamover-api |
#                  trilio-horizon-plugin | trilio-wlm
#
# Examples:
#   bash devops-build-publish.sh 6.2.0-2025.1 rocky
#   bash devops-build-publish.sh 6.2.0-2025.1 ubuntu
#   bash devops-build-publish.sh 6.2.0-2025.1 rocky trilio-datamover
#
# Published image format:
#   docker.io/trilio/kolla-<platform>-<container>:<tag>
#   e.g. docker.io/trilio/kolla-rocky-trilio-datamover:6.2.0-2025.1
#        docker.io/trilio/kolla-ubuntu-trilio-datamover:6.2.0-2025.1

set -e

usage() {
    cat <<EOF
Usage: $0 <tag> <os_platform> [container]

  tag          Docker image tag (any format), e.g. 6.2.0-2025.1
  os_platform  OS platform to build for: rocky | ubuntu
  container    (optional) Build and publish a single container.
               If omitted, all 4 containers are built.

Containers:
  trilio-datamover        Compute node datamover
  trilio-datamover-api    Control plane datamover API
  trilio-horizon-plugin   OpenStack Horizon UI plugin
  trilio-wlm              Workload Manager

Published image format:
  docker.io/trilio/kolla-<platform>-<container>:<tag>

Environment:
  DEB_REPO_URL          Trilio APT source line written to trilio.list (ubuntu)
  RPM_REPO_URL          Trilio RPM repo baseurl written to trilio.repo (rocky)
  OPENSTACK_RELEASE     Dockerfile release to build (default 2025.1)
  TRILIO_PIP_INDEX_URL  Trilio PyPI index for trilio-horizon-plugin

Examples:
  $0 6.2.0-2025.1 rocky
  $0 6.2.0-2025.1 ubuntu
  $0 6.2.0-2025.1 rocky trilio-datamover
  RPM_REPO_URL=https://yum.fury.io/<repo>/ $0 6.3.0-2025.1 rocky
  DEB_REPO_URL='deb [trusted=yes] https://apt.fury.io/<repo>/ /' $0 6.3.0-2025.1 ubuntu

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
OPENSTACK_RELEASE="${OPENSTACK_RELEASE:-2025.1}"
TRILIO_PIP_INDEX_URL="${TRILIO_PIP_INDEX_URL:-https://pypi.fury.io/trilio-6-2/}"

case "$PLATFORM" in
    rocky|ubuntu) ;;
    *)
        echo "ERROR: Unsupported os_platform '$PLATFORM'. Use rocky or ubuntu."
        exit 1
        ;;
esac

ALL_CONTAINERS=(trilio-datamover trilio-datamover-api trilio-horizon-plugin trilio-wlm)
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
        SOURCE_DF="$BASE_DIR/$CONTAINER/Dockerfile_2025.1_${PLATFORM}"
    fi

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

    if [ "$PLATFORM" = "ubuntu" ]; then
        REPO_FILE="trilio.list"; REPO_VAR="DEB_REPO_URL"; REPO_VALUE="${DEB_REPO_URL:-}"
    else
        REPO_FILE="trilio.repo"; REPO_VAR="RPM_REPO_URL"; REPO_VALUE="${RPM_REPO_URL:-}"
    fi
    if [ -f "$CONT_BUILD_DIR/$REPO_FILE" ] && grep -q "$REPO_FILE" "$CONT_BUILD_DIR/Dockerfile"; then
        if [ -z "$REPO_VALUE" ]; then
            echo "ERROR: $CONTAINER installs Trilio packages from $REPO_FILE; set $REPO_VAR."
            exit 1
        fi
        sed -i "s|{$REPO_VAR}|$REPO_VALUE|g" "$CONT_BUILD_DIR/$REPO_FILE"
    fi

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
