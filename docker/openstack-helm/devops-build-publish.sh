#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O OpenStack Helm / MOSK container images.
#
# Usage:
#   bash devops-build-publish.sh <tag> <openstack_release> [container]
#
# Arguments:
#   tag               Docker image tag (any format), e.g. 5.2.7-mosk22.4
#   openstack_release Release suffix matching the Dockerfile name, e.g. mosk22.4_yoga
#   container         (optional) Build only this container:
#                       trilio-wlm | trilio-datamover-api |
#                       trilio-datamover | trilio-horizon-plugin
#                     If omitted, all 4 containers are built.
#
# Environment variables:
#   DEB_REPO_URL  Debian package repository URL substituted into trilio.list
#                 (replaces the {DEB_REPO_URL} placeholder).
#                 Required when building containers that use trilio.list.
#
# Published image format:
#   docker.io/trilio/<container>-helm:<tag>-<openstack_release>
#   e.g. docker.io/trilio/trilio-wlm-helm:5.2.7-mosk22.4_yoga
#        docker.io/trilio/trilio-datamover-helm:5.2.7-mosk22.4_yoga

set -e

usage() {
    cat <<EOF
Usage: $0 <tag> <openstack_release> [container]

  tag               Docker image tag, e.g. 5.2.7-mosk22.4
  openstack_release Release suffix used in Dockerfile name, e.g. mosk22.4_yoga
  container         (optional) Build and publish a single container.
                    If omitted, all 4 containers are built.

Containers:
  trilio-wlm              Workload Manager
  trilio-datamover-api    Control plane Datamover API
  trilio-datamover        Compute node Datamover
  trilio-horizon-plugin   OpenStack Horizon UI plugin

Environment variables:
  DEB_REPO_URL  Debian package repo URL (substituted into trilio.list)

Published image format:
  docker.io/trilio/<container>-helm:<tag>-<openstack_release>

Examples:
  $0 5.2.7-mosk22.4 mosk22.4_yoga
  $0 5.2.7-mosk22.4 mosk22.4_yoga trilio-datamover
  DEB_REPO_URL=https://repo.fury.io/trilio/ $0 5.2.7-mosk22.4 mosk22.4_yoga

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
OPENSTACK_RELEASE="$2"
SINGLE_CONTAINER="${3:-}"

ALL_CONTAINERS=(trilio-wlm trilio-datamover-api trilio-datamover trilio-horizon-plugin)

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
echo " T4O OpenStack Helm / MOSK Build & Publish"
echo " Tag              : $TAG"
echo " OpenStack release: $OPENSTACK_RELEASE"
if [ -n "$SINGLE_CONTAINER" ]; then
echo " Container        : $SINGLE_CONTAINER (single)"
else
echo " Container        : all"
fi
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${TAG}_${OPENSTACK_RELEASE}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

for CONTAINER in "${ALL_CONTAINERS[@]}"; do

    if [ -n "$SINGLE_CONTAINER" ] && [ "$SINGLE_CONTAINER" != "$CONTAINER" ]; then
        continue
    fi

    SOURCE_DF="$BASE_DIR/$CONTAINER/Dockerfile_${OPENSTACK_RELEASE}"

    if [ ! -f "$SOURCE_DF" ]; then
        echo ""
        echo "SKIP: $CONTAINER — $(basename "$SOURCE_DF") not found"
        continue
    fi

    IMAGE="docker.io/trilio/${CONTAINER}-helm:${TAG}-${OPENSTACK_RELEASE}"

    echo ""
    echo "--------------------------------------------------"
    echo " Building : $IMAGE"
    echo "--------------------------------------------------"

    CONT_BUILD_DIR="$BUILD_DIR/$CONTAINER"
    cp -R "$BASE_DIR/$CONTAINER" "$CONT_BUILD_DIR"
    cp "$SOURCE_DF" "$CONT_BUILD_DIR/Dockerfile"
    rm -f "$CONT_BUILD_DIR/Dockerfile_"*

    # Substitute DEB_REPO_URL placeholder in trilio.list if present
    if [ -f "$CONT_BUILD_DIR/trilio.list" ] && [ -n "${DEB_REPO_URL:-}" ]; then
        sed -i "s|{DEB_REPO_URL}|${DEB_REPO_URL}|g" "$CONT_BUILD_DIR/trilio.list"
    fi

    docker build --no-cache --pull --network host -t "$IMAGE" "$CONT_BUILD_DIR"
    docker push "$IMAGE"

    echo " Published : $IMAGE"
done

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
