#!/bin/bash
# cleanup_legacy_mounts_osh.sh
# Removes zombie host mounts left by T4O 5.x object-store pods
# Run this AFTER the helm upgrade to 6.2

set -e

NAMESPACE="trilio-openstack"

echo "=========================================================="
echo " Cleaning Up Zombie Mounts (T4O 5.2/6.1 -> 6.2)"
echo "=========================================================="

# 1. Verify object-store is gone
if kubectl get daemonset triliovault-object-store -n $NAMESPACE >/dev/null 2>&1; then
    echo "ERROR: triliovault-object-store DaemonSet is still running."
    echo "Please ensure you have upgraded the Helm chart to 6.2 before running this cleanup."
    exit 1
fi

# 2. Get an image we know is cached locally to work in air-gapped environments
CLEANUP_IMAGE=$(kubectl get ds triliovault-dms -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "ubuntu:20.04")

echo "Using image $CLEANUP_IMAGE for cleanup daemonset..."

# 3. Create the cleanup DaemonSet
cat <<EOF > /tmp/trilio-cleanup-ds.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: trilio-mount-cleanup
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      name: trilio-mount-cleanup
  template:
    metadata:
      labels:
        name: trilio-mount-cleanup
    spec:
      hostPID: true
      tolerations:
      - operator: "Exists"
      containers:
      - name: cleanup
        image: $CLEANUP_IMAGE
        securityContext:
          privileged: true
        command:
        - nsenter
        - -t
        - "1"
        - -m
        - -u
        - -i
        - -n
        - bash
        - -c
        - |
          echo "Starting cleanup..."
          for m in \$(findmnt -r -n -o TARGET | grep '/var/lib/trilio/triliovault-mounts/' || true); do
              echo "Unmounting \$m"
              umount -l "\$m" || true
          done
          echo "Cleaning up directories..."
          rm -rf /var/lib/trilio/triliovault-mounts/* || true
          echo "Cleanup complete."
          sleep infinity
EOF

echo "Deploying temporary cleanup DaemonSet..."
kubectl apply -f /tmp/trilio-cleanup-ds.yaml

echo "Waiting for DaemonSet pods to be scheduled and run..."
# Wait for the daemonset to roll out so we know pods are running
sleep 5
kubectl rollout status daemonset/trilio-mount-cleanup -n $NAMESPACE --timeout=120s || true

# Give the pods an extra 10 seconds to finish the quick bash script
sleep 10

echo "Cleanup execution sample from one node:"
CLEANUP_POD=$(kubectl get pods -n $NAMESPACE -l name=trilio-mount-cleanup -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)
if [ -n "$CLEANUP_POD" ]; then
    kubectl logs $CLEANUP_POD -n $NAMESPACE || true
fi

echo "Removing temporary DaemonSet..."
kubectl delete -f /tmp/trilio-cleanup-ds.yaml --ignore-not-found=true

rm -f /tmp/trilio-cleanup-ds.yaml

echo "=========================================================="
echo " Zombie mounts successfully cleaned!"
echo "=========================================================="
