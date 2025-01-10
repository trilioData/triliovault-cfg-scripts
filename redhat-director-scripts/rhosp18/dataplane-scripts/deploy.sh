#!/bin/bash -x

set -e

oc -n openstack apply -f cm-trilio-datamover.yaml
oc -n openstack apply -f trilio-datamover-service.yaml
