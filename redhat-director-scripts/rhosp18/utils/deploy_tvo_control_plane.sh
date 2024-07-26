#!/bin/bash -x

## Install TVO Control Plane Services
kubectl -n triliovault apply -f ./tvo-operator-inputs.yaml

