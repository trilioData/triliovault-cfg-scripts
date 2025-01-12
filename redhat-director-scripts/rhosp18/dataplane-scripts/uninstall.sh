#!/bin/bash -x

set -e

oc -n openstack delete -f cm-trilio-datamover.yaml
oc -n openstack delete -f trilio-datamover-service.yaml

echo -e "Successfully delete trilio resources from openshift. Please follow uninstall document for remaining steps"
