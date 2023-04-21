#!/bin/bash -x

helm delete triliovault
kubectl delete job triliovault-datamover-db-init -n triliovault
kubectl delete job triliovault-wlm-db-init -n triliovault
kubectl delete job triliovault-datamover-db-sync -n triliovault
kubectl delete job triliovault-wlm-db-sync -n triliovault
kubectl delete job triliovault-datamover-ks-service -n triliovault
kubectl delete job triliovault-datamover-ks-endpoints -n triliovault
kubectl delete job triliovault-datamover-ks-user -n triliovault
kubectl delete job triliovault-wlm-ks-endpoints -n triliovault
kubectl delete job triliovault-wlm-ks-service -n triliovault
kubectl delete job triliovault-wlm-ks-user -n triliovault
kubectl delete job triliovault-wlm-rabbit-init -n triliovault
kubectl delete job triliovault-datamover-db-drop
kubectl delete job triliovault-wlm-db-drop
kubectl delete job triliovault-wlm-cloud-trust


sleep 50s

export replicasets=`kubectl -n triliovault get rs --no-headers -o custom-columns=":metadata.name"`

for rs in $replicasets
do
  echo -e "Patching ReplicaSet Name: $rs"
  kubectl -n triliovault patch rs $rs --type JSON --patch-file patch.yaml
  echo -e "Deleting ReplicaSet $rs"
  kubectl delete rs $rs
done


export pods=`kubectl -n triliovault get pods --no-headers -o custom-columns=":metadata.name"`

for pod in $pods
do
  echo -e "Patching Pod: $pod"
  kubectl -n triliovault patch pod $pod --type JSON --patch-file patch.yaml
  echo -e "Deleting pod $pod"
  kubectl delete pod $pod
done


kubectl get pods -n triliovault | grep trilio
kubectl get jobs -n triliovault | grep trilio
kubectl get pv -n triliovault | grep trilio

