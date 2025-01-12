#!/bin/bash -x

## Install TVO Control Plane Services
oc -n trilio-openstack create -f operator-rbac.yaml
oc -n trilio-openstack apply -f ./tvo-operator-inputs.yaml

