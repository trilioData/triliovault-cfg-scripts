#!/bin/bash -x

set -e

if [ $# -lt 2 ]; then
   echo "Script takes exactly 2 arguments"
   echo -e "./get_admin_creds.sh <TRILIO_REGISTRY_USERNAME> <TRILIO_REGISTRY_PASSWORD>"
   exit 1
fi

TRILIO_REGISTRY_USERNAME=$1
TRILIO_REGISTRY_PASSWORD=$2

# Namespaces to apply the secret in
NAMESPACES=("trilio-openstack" "openstack")

for NS in "${NAMESPACES[@]}"; do
  echo "Creating secret in namespace: $NS"
  kubectl create secret docker-registry triliovault-image-registry \
     --docker-server="docker.io" \
     --docker-username="${TRILIO_REGISTRY_USERNAME}" \
     --docker-password="${TRILIO_REGISTRY_PASSWORD}" \
     -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
done
kubectl describe secret triliovault-image-registry -n trilio-openstack

echo "Trilio image pull secret created in both 'trilio-openstack' and 'openstack' namespaces."
