#!/bin/bash
# collect_rabbitmq_creds.sh
# Dynamically extracts active credentials from the RabbitMQ Cluster Operator
# and generates a temporary values override for OpenStack-Helm upgrades.

NAMESPACE="trilio-openstack"
OUTPUT_FILE="./trilio-openstack/values_overrides/rabbitmq_upgrade_creds.yaml"

echo "Collecting dynamic RabbitMQ Cluster Operator credentials..."
RABBIT_USER=$(kubectl get secret rabbitmq-default-user -n $NAMESPACE -o jsonpath='{.data.username}' | base64 -d)
RABBIT_PASS=$(kubectl get secret rabbitmq-default-user -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$RABBIT_USER" ] || [ -z "$RABBIT_PASS" ]; then
    echo "Error: Could not find rabbitmq-default-user secret. Is RabbitMQ Operator deployed?"
    exit 1
fi

cat <<EOF > $OUTPUT_FILE
endpoints:
  oslo_messaging_wlm:
    auth:
      admin:
        username: "$RABBIT_USER"
        password: "$RABBIT_PASS"
  oslo_messaging_datamover:
    auth:
      admin:
        username: "$RABBIT_USER"
        password: "$RABBIT_PASS"
EOF

echo "Generated runtime credentials file: $OUTPUT_FILE"
