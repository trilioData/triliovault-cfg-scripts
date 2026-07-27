#!/bin/bash
# devops-build-publish.sh
#
# Builds and publishes T4O RHOSO 18 images:
#   - TVO Operator   (control plane): docker.io/trilio/tvo-operator:<tag>
#   - Ansible Runner (data plane):    docker.io/trilio/rhoso-ansible-runner:<tag>
#
# Usage:
#   bash devops-build-publish.sh <tag> [--openstack-version <RHOSO 18 version>]
#
# Arguments:
#   tag  Image tag (any format), e.g. 6.2.0-rhoso18.0 or tv7336
#
# Options:
#   --openstack-version   RHOSO 18 version this operator build targets, e.g. 18.0.18
#                          or 18.0.21 (matches 'oc get openstackversion' on the target
#                          cluster). <18.0.21 -> upstream community RabbitMQ Cluster
#                          Operator (default). >=18.0.21 -> RHOSO's native RabbitMQ
#                          operator (rabbitmq.openstack.org). See TVAULT-7511.
#
# Prerequisites:
#   - operator-sdk and make must be available (for tvo-operator build)
#   - buildah and podman must be available (for ansible-runner build)
#   - Logged in to docker.io (docker login / podman login)

set -e

usage() {
    cat <<EOF
Usage: $0 <tag> [--openstack-version <RHOSO 18 version>]

  tag                  Image tag (any format), e.g. 6.2.0-rhoso18.0 or tv7336
  --openstack-version  RHOSO 18 version this build targets, e.g. 18.0.18 or 18.0.21
                        <18.0.21  -> upstream community RabbitMQ Cluster Operator (default)
                        >=18.0.21 -> RHOSO's native RabbitMQ operator (rabbitmq.openstack.org)

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

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

TAG="$1"
shift

OPENSTACK_VERSION="18.0.18"
while [ $# -gt 0 ]; do
    case "$1" in
        --openstack-version)
            OPENSTACK_VERSION="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument $1"
            usage
            exit 1
            ;;
    esac
done

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=================================================="
echo " T4O RHOSO 18 Build & Publish"
echo " Tag : $TAG"
echo " OpenStack version : $OPENSTACK_VERSION"
echo "=================================================="

# ── Control plane: TVO Operator ──────────────────────────────────────────────
echo ""
echo "--------------------------------------------------"
echo " Building control plane: tvo-operator:$TAG"
echo "--------------------------------------------------"

OPERATOR_DIR="$BASE_DIR/ctlplane-scripts/operator/tvo-operator"

if [ ! -d "$OPERATOR_DIR" ]; then
    echo "ERROR: operator source not found at $OPERATOR_DIR"
    exit 1
fi

CHART_TEMPLATES_DIR="$OPERATOR_DIR/helm-charts/tvo-chart/templates"

# RHOSO switched RabbitMQ from the upstream community RabbitMQ Cluster Operator to its
# own native operator starting with 18.0.21 (TVAULT-7511). templates/rabbitmq/ holds the
# native (>=18.0.21) resources; templates/rabbitmq-till-18.0.18/ holds the community
# operator (<18.0.21) resources. Only one of the two may ship in a given build - some
# clusters register both CRDs at once, so keeping both would create duplicate resources.
BASE_VERSION="$(echo "$OPENSTACK_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
SMALLER="$(printf '%s\n%s\n' "18.0.21" "$BASE_VERSION" | sort -V | head -n1)"
if [ "$SMALLER" = "18.0.21" ]; then
    # OPENSTACK_VERSION >= 18.0.21
    rm -rf "$CHART_TEMPLATES_DIR/rabbitmq-till-18.0.18"
else
    # OPENSTACK_VERSION < 18.0.21
    rm -rf "$CHART_TEMPLATES_DIR/rabbitmq"
    mv "$CHART_TEMPLATES_DIR/rabbitmq-till-18.0.18" "$CHART_TEMPLATES_DIR/rabbitmq"
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
