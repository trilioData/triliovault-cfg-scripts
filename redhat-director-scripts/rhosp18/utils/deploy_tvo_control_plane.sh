#!/bin/bash -x

## Install TVO Control Plane Services
oc apply -f ../operator/tvo-operator/config/samples/tvo_v1alpha1_tvocontrolplane.yaml