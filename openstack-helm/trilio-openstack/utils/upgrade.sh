#!/bin/bash -x
cd ../../


helm upgrade trilio-openstack ./trilio-openstack --namespace=trilio-openstack \
--values=./trilio-openstack/values_overrides/image_pull_secrets.yaml \
--values=./trilio-openstack/values_overrides/keystone.yaml \
--values=./trilio-openstack/values_overrides/nfs.yaml \
--values=./trilio-openstack/values_overrides/2023.2.yaml \
--values=./trilio-openstack/values_overrides/admin_creds.yaml \
--values=./trilio-openstack/values_overrides/tls_public_endpoint.yaml \
--values=./trilio-openstack/values_overrides/ceph.yaml \
--values=./trilio-openstack/values_overrides/ingress.yaml \
--values=./trilio-openstack/values_overrides/triliovault_passwords.yaml

echo -e "Waiting for triliovault pods to get into running state"

./trilio-openstack/utils/wait_for_pods.sh trilio-openstack

kubectl get pods -n trilio-openstack
