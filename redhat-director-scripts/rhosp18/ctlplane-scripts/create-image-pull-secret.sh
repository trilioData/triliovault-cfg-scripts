#!/bin/bash -x

if [ $# -lt 2 ]; then
   echo "Script takes exactly 2 arguments"
   echo -e "./create-image-pull-secret.sh <TRILIO_IMAGE_REGISTRY_URL> <TRILIO_IMAGE_REGISTRY_USER>"
   echo -e "./create-image-pull-secret.sh registry.connect.redhat.com testuser"
   echo -e "This script reads container image password from secret trilio-openstack-secret"
   exit 1
fi

REGISTRY=$1
USER=$2

# Fetch and decode the ContainerRegistryPassword from the secret
PASSWORD=$(oc get secret trilio-openstack-secret -n trilio-openstack -o jsonpath='{.data.ContainerRegistryPassword}' | base64 -d)

if [ -z "$PASSWORD" ]; then
   echo "Failed to retrieve ContainerRegistryPassword from the secret"
   exit 2
fi

oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > authfile
podman login --authfile authfile --username $USER --password $PASSWORD $REGISTRY
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile
