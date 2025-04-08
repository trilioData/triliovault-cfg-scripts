#!/bin/bash -x
cd ../..
helm template -f trilio-openstack/values_overrides/admin_creds.yaml \
-f trilio-openstack/values_overrides/image_pull_secrets.yaml \
-f trilio-openstack/values_overrides/keystone.yaml \
-f trilio-openstack/values_overrides/s3.yaml \
-f trilio-openstack/values_overrides/ceph.yaml \
-f trilio-openstack/values_overrides/tls_public_endpoint.yaml \
-f trilio-openstack/values_overrides/ingress.yaml \
-f trilio-openstack/values_overrides/victoria-ubuntu_focal.yaml \
-f trilio-openstack/values_overrides/triliovault_passwords.yaml \
-f trilio-openstack/values_overrides/db_drop.yaml \
-f trilio-openstack/values_overrides/admin_creds.yaml \
--debug trilio-openstack > /tmp/trilio-manifest.yaml
