#!/bin/bash -x

## Install TVO Control Plane Services
oc create -f operator-rbac.yaml
oc -n trilio-system apply -f ./tvo-operator-inputs.yaml

