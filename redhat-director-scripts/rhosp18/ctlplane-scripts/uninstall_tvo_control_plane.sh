#!/bin/bash -x

## Install TVO Control Plane Services
oc -n trilio-openstack delete -f ./tvo-operator-inputs.yaml

# RabbitMQ cluster CR is a Helm post-install/post-upgrade hook resource, so it isn't
# cleaned up automatically when the release is deleted above. Its kind depends on
# whether this cluster runs the old community RabbitMQ Cluster Operator or RHOSO's
# native one from FR6 (18.0.21) onwards (TVAULT-7511).
OPENSTACK_VERSION="$(oc get openstackversion openstack-controlplane -n openstack -o jsonpath='{.status.deployedVersion}')"
BASE_VERSION="$(echo "$OPENSTACK_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
SMALLER="$(printf '%s\n%s\n' "18.0.21" "$BASE_VERSION" | sort -V | head -n1)"
if [ "$SMALLER" = "18.0.21" ]; then
  # OPENSTACK_VERSION >= 18.0.21 (FR6 onwards)
  oc -n trilio-openstack delete rabbitmq.rabbitmq.openstack.org trilio-rabbitmq-cluster
else
  # OPENSTACK_VERSION < 18.0.21 (till FR5)
  oc -n trilio-openstack delete rabbitmqcluster trilio-rabbitmq-cluster
fi
