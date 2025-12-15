#!/bin/bash -x

## Install TVO Control Plane Services
oc -n trilio-openstack delete -f ./tvo-operator-inputs.yaml
oc get csv -n trilio-openstack | grep -E 'rabbitmq-cluster-operator|rabbitmq-messaging-topology-operator' | awk '{print $1}' | xargs -r oc delete csv -n trilio-openstack
oc delete rabbitmqcluster trilio-rabbitmq-cluster

