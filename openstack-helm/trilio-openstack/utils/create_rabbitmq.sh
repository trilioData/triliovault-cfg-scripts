#!/bin/bash

# Script to install RabbitMQ Cluster Operator CRDs and apply RabbitmqCluster to Kubernetes

set -euo pipefail

# Namespace
NAMESPACE="trilio-openstack"

# Install RabbitMQ Cluster Operator (CRD + controller)
echo "Installing RabbitMQ Cluster Operator..."
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# Ensure namespace exists
kubectl get ns $NAMESPACE >/dev/null 2>&1 || kubectl create ns $NAMESPACE

# Define the RabbitmqCluster YAML
cat << EOF > rabbitmq-trilio.yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: rabbitmq
  namespace: $NAMESPACE
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: openstack-control-plane
            operator: In
            values:
            - enabled
  delayStartSeconds: 0
  image: docker.io/library/rabbitmq:3.13.3-management
  override: {}
  persistence:
    storage: 10Gi
  rabbitmq:
    additionalConfig: |
      vm_memory_high_watermark.relative = 0.9
  replicas: 1
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
  secretBackend:
    externalSecret: {}
  service:
    type: ClusterIP
  terminationGracePeriodSeconds: 15
  tls: {}
EOF

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed. Please install kubectl and try again."
    exit 1
fi

# Apply the RabbitmqCluster configuration
echo "Applying RabbitmqCluster configuration..."
kubectl apply -f rabbitmq-trilio.yaml

# Wait for RabbitMQ pods to be ready
echo "Waiting for RabbitMQ pods to become Ready..."
for i in {1..60}; do
    READY=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
    if [[ "$READY" == "true" ]]; then
        echo "RabbitMQ pods are Ready!"
        break
    else
        echo "Still waiting... ($i/60)"
        sleep 5
    fi
    if [[ $i -eq 60 ]]; then
        echo "Timeout: RabbitMQ pods did not become Ready in time"
        exit 1
    fi
done

# Show cluster status
kubectl get rabbitmqcluster -n $NAMESPACE rabbitmq
kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq

# Clean up
rm rabbitmq-trilio.yaml
echo "Cleanup complete: Temporary YAML file removed"
