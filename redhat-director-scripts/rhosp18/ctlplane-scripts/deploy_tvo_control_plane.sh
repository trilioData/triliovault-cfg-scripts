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

# TVAULT-7556: up to 6.2.0 the Galera and RabbitMQ CRs were templated as Helm hooks, so
# Helm never stamped them with resource-ownership metadata. From 6.2.1 they are plain
# templated resources, and Helm refuses to adopt a pre-existing object it did not stamp -
# the upgrade then aborts at "invalid ownership metadata" before a candidate release is
# built, leaving the control plane silently on the old build.
#
# This must run BEFORE tvo-operator-inputs.yaml is applied, because applying the CR is
# what triggers the helm-operator's upgrade. It is required for any upgrade coming from
# 6.1.x or 6.2.0 no matter which 6.2.x is being installed (6.2.1, 6.2.2, ...), it is
# idempotent, and it is a no-op on a fresh install.
./patch_helm_ownership_metadata.sh

oc -n trilio-openstack apply -f ./tvo-operator-inputs.yaml
