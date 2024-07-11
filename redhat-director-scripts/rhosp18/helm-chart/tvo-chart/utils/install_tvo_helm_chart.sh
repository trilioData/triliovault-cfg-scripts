#!/bin/bash -x
cd ../../


helm upgrade --install tvo-chart ./tvo-chart --namespace=triliovault \
--values=./triliovault/values_overrides/trilio_inputs_dynamic.yaml \
--values=./triliovault/values_overrides/trilio_inputs.yaml \
--values=./triliovault/values_overrides/nfs.yaml \
--values=./triliovault/values_overrides/mosk22.5_yoga.yaml \
--values=./triliovault/values_overrides/admin_creds.yaml \
--values=./triliovault/values_overrides/tls_public_endpoint.yaml \
--values=./triliovault/values_overrides/ceph.yaml \
--values=./triliovault/values_overrides/db_drop.yaml \
--values=./triliovault/values_overrides/ingress.yaml \
--values=./triliovault/values_overrides/triliovault_passwords.yaml

echo -e "Waiting for triliovault pods to get into running state"

./triliovault/utils/wait_for_pods.sh triliovault

kubectl get pods
