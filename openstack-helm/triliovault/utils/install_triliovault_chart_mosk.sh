#!/bin/bash -x
cd ../../


helm upgrade --install triliovault ./triliovault --namespace=triliovault \
--values=./triliovault/values_overrides/image_pull_secrets.yaml \
--values=./triliovault/values_overrides/conf_triliovault.yaml \
--values=./triliovault/values_overrides/victoria-ubuntu_focal.yaml \
--values=./triliovault/values_overrides/admin_creds.yaml \
--values=./triliovault/values_overrides/tls_public_endpoint.yaml \
--values=./triliovault/values_overrides/ceph.yaml

echo -e "Waiting for triliovault pods to get into running state"

./triliovault/utils/wait_for_pods.sh triliovault

kubectl get pods
