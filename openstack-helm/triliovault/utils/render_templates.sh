#!/bin/bash -x
cd ../..
helm template -f triliovault/values_overrides/admin_creds.yaml \
-f triliovault/values_overrides/image_pull_secrets.yaml \
-f triliovault/values_overrides/keystone.yaml \
-f triliovault/values_overrides/s3.yaml \
-f triliovault/values_overrides/ceph.yaml \
-f triliovault/values_overrides/tls_public_endpoint.yaml \
-f triliovault/values_overrides/ingress.yaml \
-f triliovault/values_overrides/victoria-ubuntu_focal.yaml \
-f triliovault/values_overrides/triliovault_passwords.yaml \
-f triliovault/values_overrides/db_drop.yaml \
-f triliovault/values_overrides/admin_creds.yaml \
--debug triliovault > triliovault/utils/manifest.yaml
