#!/bin/bash -x

## Install TVO Control Plane Services
oc -n triliovault delete -f ./tvo-operator-inputs.yaml

