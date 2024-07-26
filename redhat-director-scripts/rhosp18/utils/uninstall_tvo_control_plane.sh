#!/bin/bash -x

## Install TVO Control Plane Services
kubectl -n triliovault delete -f ./tvo-operator-inputs.yaml

