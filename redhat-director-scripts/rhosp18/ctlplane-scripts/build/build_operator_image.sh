#!/bin/bash

set -ex

usage() {
  echo "Usage: $0 <TAG> [--openstack-version <RHOSO 18 version>]"
  echo "  --openstack-version   RHOSO 18 version this operator build targets, e.g. 18.0.18 or 18.0.21"
  echo "                        (matches 'oc get openstackversion' on the target cluster)."
  echo "                        <18.0.21  -> templates/rabbitmq-till-18.0.18 (community RabbitMQ Cluster Operator, default)"
  echo "                        >=18.0.21 -> templates/rabbitmq (RHOSO's native RabbitMQ operator, rabbitmq.openstack.org)"
}

# Check if TAG argument is provided
if [ -z "$1" ]; then
  echo "Error: TAG argument is required."
  usage
  exit 1
fi

# Assign the first argument to TAG variable
TAG=$1
shift

OPENSTACK_VERSION="18.0.18"
while [ $# -gt 0 ]; do
  case "$1" in
    --openstack-version)
      OPENSTACK_VERSION="$2"
      shift 2
      ;;
    *)
      echo "Error: unknown argument $1"
      usage
      exit 1
      ;;
  esac
done

CHART_TEMPLATES_DIR="../operator/tvo-operator/helm-charts/tvo-chart/templates"

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

cd ../operator/tvo-operator
export IMG=docker.io/trilio/tvo-operator:$TAG
make docker-build IMG=$IMG
