#!/bin/bash -x

helm delete triliovault-openstack-chart
oc delete job job-triliovault-wlm-cloud-trust job-triliovault-datamover-api-db-init job-triliovault-datamover-api-keystone-init \
      job-triliovault-wlm-db-init job-triliovault-wlm-keystone-init
sleep 50s

oc get pods -n triliovault | grep trilio
oc get jobs -n triliovault | grep trilio

