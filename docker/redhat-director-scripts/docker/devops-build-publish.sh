#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O RHOSP 17 container images.
#
# Usage:
#   bash devops-build-publish.sh <tag> <rhosp_release> [container]
#
# Arguments:
#   tag           Docker image tag (any format), e.g. 6.2.0-rhosp17.1 or tv7336
#   rhosp_release Release suffix matching the Dockerfile name, e.g. rhosp17.1
#   container     (optional) Build only this container:
#                   trilio-wlm | trilio-datamover-api |
#                   trilio-datamover | trilio-horizon-plugin
#                 If omitted, all 4 containers are built.
#
# Environment variables (required):
#   RPM_REPO_URL  Trilio RPM repo baseurl, substituted into trilio.repo
#
# Published image format:
#   docker.io/trilio/<container>:<tag>
#   e.g. docker.io/trilio/trilio-wlm:tv7336
#        docker.io/trilio/trilio-datamover:tv7336

set -e

usage() {
    cat <<EOF
Usage: $0 <tag> <rhosp_release> [container]

  tag           Docker image tag, e.g. tv7336
  rhosp_release Release suffix used in Dockerfile name, e.g. rhosp17.1
  container     (optional) Build and publish a single container.
                If omitted, all 4 containers are built.

Containers:
  trilio-wlm              Workload Manager
  trilio-datamover-api    Control plane Datamover API
  trilio-datamover        Compute node Datamover
  trilio-horizon-plugin   OpenStack Horizon UI plugin

Environment variables (required):
  RPM_REPO_URL  Trilio RPM repo baseurl (substituted into trilio.repo)

Published image format:
  docker.io/trilio/<container>:<tag>

Examples:
  RPM_REPO_URL='https://...' $0 tv7336 rhosp17.1
  RPM_REPO_URL='https://...' $0 tv7336 rhosp17.1 trilio-datamover

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
RHOSP_RELEASE="$2"
SINGLE_CONTAINER="${3:-}"

# Repo URL must be supplied via environment variable — read from the
# "Latest Build Details" Confluence page for the matching T4O release.
if [ -z "${RPM_REPO_URL:-}" ]; then
    echo "ERROR: RPM_REPO_URL env var is required."
    exit 1
fi

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
echo " T4O RHOSP 17 Build & Publish"
echo " Tag          : $TAG"
echo " RHOSP release: $RHOSP_RELEASE"
if [ -n "$SINGLE_CONTAINER" ]; then
echo " Container    : $SINGLE_CONTAINER (single)"
else
echo " Container    : all"
fi
echo "=================================================="

BUILD_DIR="$BASE_DIR/tmp_devops_${TAG}_${RHOSP_RELEASE}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

for CONTAINER in "${ALL_CONTAINERS[@]}"; do

    if [ -n "$SINGLE_CONTAINER" ] && [ "$SINGLE_CONTAINER" != "$CONTAINER" ]; then
        continue
    fi

    SOURCE_DF="$BASE_DIR/$CONTAINER/Dockerfile_${RHOSP_RELEASE}"

    if [ ! -f "$SOURCE_DF" ]; then
        echo ""
        echo "SKIP: $CONTAINER — $(basename "$SOURCE_DF") not found"
        continue
    fi

    IMAGE="docker.io/trilio/${CONTAINER}:${TAG}"

    echo ""
    echo "--------------------------------------------------"
    echo " Building : $IMAGE"
    echo "--------------------------------------------------"

    CONT_BUILD_DIR="$BUILD_DIR/$CONTAINER"
    cp -R "$BASE_DIR/$CONTAINER" "$CONT_BUILD_DIR"
    cp "$SOURCE_DF" "$CONT_BUILD_DIR/Dockerfile"
    rm -f "$CONT_BUILD_DIR/Dockerfile_"*

    # Substitute RPM repo URL placeholder
    if [ -f "$CONT_BUILD_DIR/trilio.repo" ]; then
        sed -i "s|{RPM_REPO_URL}|${RPM_REPO_URL}|g" "$CONT_BUILD_DIR/trilio.repo"
    fi

    podman build --no-cache --network host -t "$IMAGE" "$CONT_BUILD_DIR"
    podman push "$IMAGE"

    echo " Published : $IMAGE"
done

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
