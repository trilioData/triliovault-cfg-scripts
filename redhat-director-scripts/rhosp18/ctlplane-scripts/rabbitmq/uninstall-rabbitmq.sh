#!/bin/bash 

oc delete RabbitmqCluster trilio-rabbitmq-cluster
oc delete subscription rabbitmq-cluster-operator -n trilio-openstack
CSV_LIST=$(oc get csv -n trilio-openstack --no-headers | grep rabbitmq | awk '{print $1}')

if [ -z "$CSV_LIST" ]; then
  echo "No RabbitMQ CSVs found in namespace $NAMESPACE."
else
  for csv in $CSV_LIST; do
    echo "Deleting CSV: $csv"
    oc delete csv $csv -n $NAMESPACE
  done
  echo "All RabbitMQ CSVs deleted from namespace $NAMESPACE."
fi
