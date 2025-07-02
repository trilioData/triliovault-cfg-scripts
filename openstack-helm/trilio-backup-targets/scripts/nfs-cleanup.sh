#!/bin/bash

set -euo pipefail

YAML_FILE="${1:-}"
if [[ ! -f "$YAML_FILE" ]]; then
  echo "[ERROR] File not found: $YAML_FILE"
  exit 1
fi

# Parse fields from YAML using yq
NFS_SHARE=$(yq eval '.trilio_backup_target.nfs_shares' "$YAML_FILE")
BT_NAME=$(yq eval '.trilio_backup_target.backup_target_name' "$YAML_FILE")
TRILIO_IMG=$(yq eval '.images.trilio_wlm' "$YAML_FILE")

if [[ -z "$NFS_SHARE" || -z "$BT_NAME" || -z "$TRILIO_IMG" ]]; then
  echo "[ERROR] Missing required fields in YAML file"
  exit 1
fi

ENCODED=$(echo -n "$NFS_SHARE" | base64 -w 0)
TARGET_PATH="/var/lib/trilio/triliovault-mounts/${ENCODED}"
DS_NAME="trilio-nfs-cleanup-${BT_NAME,,}"

echo "[INFO] Creating DaemonSet $DS_NAME to unmount $TARGET_PATH"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $DS_NAME
  namespace: trilio-openstack
  labels:
    app: trilio-nfs-cleanup
spec:
  selector:
    matchLabels:
      app: trilio-nfs-cleanup
  template:
    metadata:
      labels:
        app: trilio-nfs-cleanup
    spec:
      terminationGracePeriodSeconds: 10
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: triliovault-control-plane
                    operator: In
                    values:
                      - "enabled"
              - matchExpressions:
                  - key: openstack-compute-node
                    operator: In
                    values:
                      - "enabled"
      containers:
        - name: cleanup
          image: $TRILIO_IMG
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
            readOnlyRootFilesystem: false
            runAsUser: 0
          command:
            - /bin/bash
            - -c
            - |
              echo "[INFO] Attempting to unmount $TARGET_PATH"
              if mountpoint -q "$TARGET_PATH"; then
                umount -l "$TARGET_PATH" && echo "[INFO] Unmounted $TARGET_PATH" || echo "[WARN] Failed to unmount $TARGET_PATH"
              else
                echo "[INFO] $TARGET_PATH is not a mountpoint"
              fi
              sleep 5
              exit 0
          volumeMounts:
            - name: trilio-dir
              mountPath: /var/lib/trilio/triliovault-mounts
              mountPropagation: Bidirectional
      volumes:
        - name: trilio-dir
          hostPath:
            path: /var/lib/trilio/triliovault-mounts
            type: Directory
EOF

echo "[INFO] Waiting 30 seconds for unmount to complete..."
sleep 30

echo "[INFO] Deleting DaemonSet $DS_NAME"
kubectl delete daemonset "$DS_NAME" -n trilio-openstack
