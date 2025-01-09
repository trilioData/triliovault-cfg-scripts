#!/bin/bash -x

set -e

oc -n openstack delete -f cm-trilio-datamover.yaml
oc -n openstack delete -f trilio-datamover-service.yaml
