#!/bin/bash

# Script to install RabbitMQ Cluster Operator CRDs and apply RabbitmqCluster to Kubernetes
set -euo pipefail

# Namespace
NAMESPACE="triliovault"
CLUSTER_NAME="rabbitmq"

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed. Please install kubectl and try again."
    exit 1
fi

# Install RabbitMQ Cluster Operator (CRD + controller) only if not already present
echo "Checking RabbitMQ Cluster Operator..."
if ! kubectl get crd rabbitmqclusters.rabbitmq.com >/dev/null 2>&1; then
    echo "Installing RabbitMQ Cluster Operator..."
    kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml
else
    echo "RabbitMQ Cluster Operator already installed, skipping..."
fi

# Ensure namespace exists
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

# Create RabbitmqCluster YAML
cat << EOF > rabbitmq-trilio.yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: $CLUSTER_NAME
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

# Apply RabbitmqCluster only if not already present
if ! kubectl get rabbitmqcluster "$CLUSTER_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating RabbitmqCluster $CLUSTER_NAME in namespace $NAMESPACE..."
    kubectl apply -f rabbitmq-trilio.yaml
else
    echo "RabbitmqCluster $CLUSTER_NAME already exists, skipping..."
fi

# Wait for RabbitMQ pods to be ready
echo "Waiting for RabbitMQ pods to become Ready..."
for i in {1..60}; do
    READY=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
    if [[ "$READY" == *"true"* ]]; then
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
kubectl get rabbitmqcluster -n $NAMESPACE $CLUSTER_NAME
kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq

# Clean up
rm -f rabbitmq-trilio.yaml
echo "Cleanup complete: Temporary YAML file removed"
echo "RabbitMQ Cluster setup completed successfully."