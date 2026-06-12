#!/bin/bash -x

# upgrade6.2.sh
# Safely upgrades T4O from 6.1 to 6.2.
# 
# IMPORTANT SAFEGUARDS IN THIS SCRIPT:
# 1. EXCLUDES db_drop.yaml to prevent wiping the WLM database and backup targets.
# 2. EXCLUDES nfs.yaml and s3.yaml as those legacy architectures are deprecated in 6.2.

cd ../../

echo -e "Starting T4O 6.2 Upgrade..."

# Dynamically extract RabbitMQ credentials so Helm doesn't auto-generate new ones
bash ./trilio-openstack/utils/collect_rabbitmq_creds.sh
if [ $? -ne 0 ]; then
    echo "Failed to collect RabbitMQ credentials. Aborting upgrade."
    exit 1
fi

# We use 'upgrade --install' to safely apply changes over the existing release
helm upgrade --install trilio-openstack ./trilio-openstack --namespace=trilio-openstack \
--values=./trilio-openstack/values_overrides/image_pull_secrets.yaml \
--values=./trilio-openstack/values_overrides/keystone.yaml \
--values=./trilio-openstack/values_overrides/2023.2.yaml \
--values=./trilio-openstack/values_overrides/admin_creds.yaml \
--values=./trilio-openstack/values_overrides/tls_public_endpoint.yaml \
--values=./trilio-openstack/values_overrides/ceph.yaml \
--values=./trilio-openstack/values_overrides/ingress.yaml \
--values=./trilio-openstack/values_overrides/triliovault_passwords.yaml \
--values=./trilio-openstack/values_overrides/rabbitmq_upgrade_creds.yaml

# Clean up runtime credentials file
rm -f ./trilio-openstack/values_overrides/rabbitmq_upgrade_creds.yaml

echo -e "Waiting for trilio-openstack pods to transition to the running state..."

./trilio-openstack/utils/wait_for_pods.sh trilio-openstack

echo -e "Upgrade complete! Please proceed with running scripts/cleanup_legacy_mounts_osh.sh and scripts/migrate_backup_targets_osh.sh"

kubectl get pods -n trilio-openstack
