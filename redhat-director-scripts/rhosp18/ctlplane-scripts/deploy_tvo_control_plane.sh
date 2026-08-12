#!/bin/bash -x

## Install TVO Control Plane Services

# RHOSO switched RabbitMQ from the upstream community RabbitMQ Cluster Operator to its
# own native operator starting with FR6 (18.0.21) - the community operator is no longer
# deployed by RHOSO from that version on (TVAULT-7511). set_operator_inputs.py already
# picks the matching tvo-operator-inputs-till-fr5.yaml / tvo-operator-inputs-fr6-onwards.yaml
# template and resolves it into the canonical tvo-operator-inputs.yaml below - this is
# just a defensive check/log that the detected version still matches what was applied.
OPENSTACK_VERSION="$(oc get openstackversion openstack-controlplane -n openstack -o jsonpath='{.status.deployedVersion}')"
BASE_VERSION="$(echo "$OPENSTACK_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
SMALLER="$(printf '%s\n%s\n' "18.0.21" "$BASE_VERSION" | sort -V | head -n1)"
if [ "$SMALLER" = "18.0.21" ]; then
  echo "Detected OpenStack version: $OPENSTACK_VERSION (>=18.0.21, FR6 onwards)"
else
  echo "Detected OpenStack version: $OPENSTACK_VERSION (<18.0.21, till FR5)"
fi

oc -n trilio-openstack create -f operator-rbac.yaml

oc -n trilio-openstack apply -f ./tvo-operator-inputs.yaml
