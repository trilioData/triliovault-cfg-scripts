#!/bin/bash -x

## Install TVO Control Plane Services
oc -n trilio-openstack delete -f ./tvo-operator-inputs.yaml
oc -n trilio-openstack delete rabbitmqcluster trilio-rabbitmq-cluster
