#!/bin/bash -x
#oc create secret docker-registry custom-pull-secret \
#  --docker-server=docker.io \
#  --docker-username=${USER} \
#  --docker-password=${PASSWORD} \
#  -n openstack

USER=""
PASSWORD=""

oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > authfile
podman login --authfile authfile --username $USER --password $PASSWORD dockerhub_url
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile
