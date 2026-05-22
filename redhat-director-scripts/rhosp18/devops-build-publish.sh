#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O RHOSO 18 images:
#   - TVO Operator   (control plane): docker.io/trilio/tvo-operator:<tag>
#   - Ansible Runner (data plane):    docker.io/trilio/rhoso-ansible-runner:<tag>
#
# Usage:
#   bash devops-build-publish.sh <tag>
#
# Arguments:
#   tag  Image tag (any format), e.g. 6.2.0-rhoso18.0 or tv7336
#
# Prerequisites:
#   - operator-sdk and make must be available (for tvo-operator build)
#   - buildah and podman must be available (for ansible-runner build)
#   - Logged in to docker.io (docker login / podman login)

set -e

usage() {
    cat <<EOF
Usage: $0 <tag>

  tag  Image tag (any format), e.g. 6.2.0-rhoso18.0 or tv7336

Published images:
  docker.io/trilio/tvo-operator:<tag>
  docker.io/trilio/rhoso-ansible-runner:<tag>

Options:
  -h, --help   Show this help message and exit.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -ne 1 ]; then
    usage
    exit 1
fi

TAG="$1"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=================================================="
echo " T4O RHOSO 18 Build & Publish"
echo " Tag : $TAG"
echo "=================================================="

# ── Control plane: TVO Operator ──────────────────────────────────────────────
echo ""
echo "--------------------------------------------------"
echo " Building control plane: tvo-operator:$TAG"
echo "--------------------------------------------------"

CTLPLANE_BUILD_DIR="$BASE_DIR/ctlplane-scripts/build"
OPERATOR_DIR="$BASE_DIR/ctlplane-scripts/operator/tvo-operator"

if [ ! -d "$OPERATOR_DIR" ]; then
    echo "ERROR: operator source not found at $OPERATOR_DIR"
    exit 1
fi

cd "$OPERATOR_DIR"
export IMG="docker.io/trilio/tvo-operator:${TAG}"
make docker-build IMG="$IMG"
make docker-push IMG="$IMG"

echo " Published : $IMG"

# ── Data plane: Ansible Runner ────────────────────────────────────────────────
echo ""
echo "--------------------------------------------------"
echo " Building data plane: rhoso-ansible-runner:$TAG"
echo "--------------------------------------------------"

DATAPLANE_BUILD_DIR="$BASE_DIR/dataplane-scripts/build"
ANSIBLE_ROLES_DIR="$BASE_DIR/dataplane-scripts/ansible-roles"

if [ ! -f "$DATAPLANE_BUILD_DIR/Dockerfile" ]; then
    echo "ERROR: Dockerfile not found at $DATAPLANE_BUILD_DIR/Dockerfile"
    exit 1
fi

cd "$DATAPLANE_BUILD_DIR"
rm -rf ./ansible-roles/
cp -R "$ANSIBLE_ROLES_DIR" ./ansible-roles/

RUNNER_IMAGE="docker.io/trilio/rhoso-ansible-runner:${TAG}"
buildah bud -t "$RUNNER_IMAGE" -f Dockerfile .
podman push "$RUNNER_IMAGE"

rm -rf ./ansible-roles/

echo " Published : $RUNNER_IMAGE"

echo ""
echo "=================================================="
echo " Build and publish complete."
echo "=================================================="
