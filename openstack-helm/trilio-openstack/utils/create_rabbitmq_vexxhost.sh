#!/bin/bash

# Script to apply RabbitmqCluster to Kubernetes

# Define the YAML content
cat << EOF > rabbitmq-trilio.yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: rabbitmq-trilio
  namespace: openstack
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

# Check the status of the application
if [ $? -eq 0 ]; then
    echo "RabbitmqCluster 'rabbitmq-trilio' applied successfully!"
    echo "Verifying the cluster status..."
    sleep 5  # Wait briefly for the resource to be created
    kubectl get rabbitmqcluster -n openstack rabbitmq-trilio
else
    echo "Error: Failed to apply RabbitmqCluster configuration"
    exit 1
fi

# Clean up the YAML file
rm rabbitmq-trilio.yaml
echo "Cleanup complete: Temporary YAML file removed"
