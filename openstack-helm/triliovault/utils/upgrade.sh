#!/bin/bash -x
cd ../../


helm upgrade triliovault ./triliovault --namespace=triliovault \
--values=./triliovault/values_overrides/image_pull_secrets.yaml \
--values=./triliovault/values_overrides/keystone.yaml \
--values=./triliovault/values_overrides/nfs.yaml \
--values=./triliovault/values_overrides/victoria-ubuntu_focal.yaml \
--values=./triliovault/values_overrides/admin_creds.yaml \
--values=./triliovault/values_overrides/tls_public_endpoint.yaml \
--values=./triliovault/values_overrides/ceph.yaml \
--values=./triliovault/values_overrides/ingress.yaml \
--values=./triliovault/values_overrides/triliovault_passwords.yaml

echo -e "Waiting for triliovault pods to get into running state"

./triliovault/utils/wait_for_pods.sh triliovault

kubectl get pods
