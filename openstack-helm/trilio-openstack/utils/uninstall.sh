#!/bin/bash -x

helm delete trilio-openstack
kubectl delete job triliovault-datamover-db-init -n trilio-openstack
kubectl delete job triliovault-wlm-db-init -n trilio-openstack
kubectl delete job triliovault-datamover-db-sync -n trilio-openstack
kubectl delete job triliovault-wlm-db-sync -n trilio-openstack
kubectl delete job triliovault-datamover-ks-service -n trilio-openstack
kubectl delete job triliovault-datamover-ks-endpoints -n trilio-openstack
kubectl delete job triliovault-datamover-ks-user -n trilio-openstack
kubectl delete job triliovault-wlm-ks-endpoints -n trilio-openstack
kubectl delete job triliovault-wlm-ks-service -n trilio-openstack
kubectl delete job triliovault-wlm-ks-user -n trilio-openstack
kubectl delete job triliovault-wlm-rabbit-init -n trilio-openstack
kubectl delete job triliovault-datamover-db-drop -n trilio-openstack
kubectl delete job triliovault-wlm-db-drop -n trilio-openstack
kubectl delete job triliovault-wlm-cloud-trust -n trilio-openstack


sleep 50s

export replicasets=`kubectl -n trilio-openstack get rs --no-headers -o custom-columns=":metadata.name"`

for rs in $replicasets
do
  echo -e "Patching ReplicaSet Name: $rs"
  kubectl -n trilio-openstack patch rs $rs --type JSON --patch-file patch.yaml
  echo -e "Deleting ReplicaSet $rs"
  kubectl delete rs $rs
done


export pods=`kubectl -n trilio-openstack get pods --no-headers -o custom-columns=":metadata.name"`

for pod in $pods
do
  if [[ "$pod" == *rabbitmq* ]]; then
    continue
  fi
  echo -e "Patching Pod: $pod"
  kubectl -n trilio-openstack patch pod $pod --type JSON --patch-file patch.yaml
  echo -e "Deleting pod $pod"
  kubectl delete pod $pod
done


kubectl get pods -n trilio-openstack | grep trilio
kubectl get jobs -n trilio-openstack | grep trilio
kubectl get pv -n trilio-openstack | grep trilio

echo "[INFO] Creating fallback unmount-all DaemonSet..."

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: trilio-backup-target-mounts-cleanup
  namespace: trilio-openstack
  labels:
    app: trilio-cleanup
spec:
  selector:
    matchLabels:
      app: trilio-cleanup
  template:
    metadata:
      labels:
        app: trilio-cleanup
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
          image: openstackhelm/nova:2024.1-ubuntu_jammy
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
            readOnlyRootFilesystem: true
            runAsUser: 0
          command:
            - /bin/bash
            - -c
            - |
              echo "[INFO] Scanning and unmounting all under /var/lib/trilio/triliovault-mounts"
              for path in /var/lib/trilio/triliovault-mounts/*; do
                echo "[INFO] Attempting to unmount \$path"
                umount -l "\$path" && echo "[INFO] Unmounted \$path" || echo "[WARN] Failed to unmount \$path"
              done
              sleep 30
              exit 0
          volumeMounts:
            - name: trilio-mounts
              mountPath: /var/lib/trilio/triliovault-mounts
              mountPropagation: Bidirectional
      volumes:
        - name: trilio-mounts
          hostPath:
            path: /var/lib/trilio/triliovault-mounts
            type: Directory
EOF

echo "[INFO] Waiting 30 seconds for cleanup DaemonSet to complete"
sleep 30

echo "[INFO] Deleting cleanup DaemonSet..."
kubectl delete daemonset trilio-backup-target-mounts-cleanup -n trilio-openstack || true
