#!/bin/bash 

set -e 
TLS_CA_BUNDLE=$(oc get secret "combined-ca-bundle" -n "openstack" -o jsonpath='{.data.tls-ca-bundle\.pem}' | base64 -d)
echo "${TLS_CA_BUNDLE}" > keystone-ca.crt
oc create secret generic keystone-ca   --from-file=ca.crt=keystone-ca.crt   -n openshift-user-workload-monitoring
