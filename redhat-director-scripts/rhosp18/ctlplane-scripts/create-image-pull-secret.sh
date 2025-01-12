#!/bin/bash -x

if [ $# -lt 2 ];then
   echo "Script takes exactly 2 arguments"
   echo -e "./create-image-pull-secret.sh <TRILIO_IMAGE_REGISTRY_USER> <TRILIO_IMAGE_REGISTRY_PASSWORD>"
   exit 1
fi


USER=$1
PASSWORD=$2

oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > authfile
podman login --authfile authfile --username $USER --password $PASSWORD docker.io
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile
