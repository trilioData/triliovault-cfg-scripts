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
kubectl delete rabbitmqcluster rabbitmq -n trilio-openstack

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
  echo -e "Patching Pod: $pod"
  kubectl -n trilio-openstack patch pod $pod --type JSON --patch-file patch.yaml
  echo -e "Deleting pod $pod"
  kubectl delete pod $pod
done


kubectl get pods -n trilio-openstack | grep trilio
kubectl get jobs -n trilio-openstack | grep trilio
kubectl get pv -n trilio-openstack | grep trilio

