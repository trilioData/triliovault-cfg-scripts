#!/bin/bash -x

set -e

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 arguments"
   echo -e "./get_admin_creds.sh <TRILIO_REGISTRY_USERNAME> <TRILIO_REGISTRY_PASSWORD>"
   exit 1
fi

TRILIO_REGISTRY_USERNAME=$1
TRILIO_REGISTRY_PASSWORD=$2

kubectl create secret docker-registry triliovault-image-registry \
   --docker-server="docker.io" \
   --docker-username=${TRILIO_REGISTRY_USERNAME} \
   --docker-password=${TRILIO_REGISTRY_PASSWORD} \
   -n triliovault

kubectl describe secret triliovault-image-registry -n triliovault

echo "TrilioVault image pull secret created. Name: triliovault-image-registry"
