#!/bin/bash

oc create -f ./certificate.yaml

oc get secret cert-triliovault-wlm-public-svc -n openstack -o yaml > cert-triliovault-wlm-public-svc.yaml
oc get secret cert-triliovault-wlm-internal-svc -n openstack -o yaml > cert-triliovault-wlm-internal-svc.yaml

sed -i 's/openstack/triliovault/' cert-triliovault-wlm-internal-svc.yaml
sed -i 's/openstack/triliovault/' cert-triliovault-wlm-public-svc.yaml

oc create -f cert-triliovault-wlm-public-svc.yaml
oc create -f cert-triliovault-wlm-internal-svc.yaml

oc describe secret cert-triliovault-wlm-public-svc
oc describe secret cert-triliovault-wlm-internal-svc


oc get secret cert-triliovault-datamover-public-svc -n openstack -o yaml > cert-triliovault-datamover-public-svc.yaml
oc get secret cert-triliovault-datamover-internal-svc -n openstack -o yaml > cert-triliovault-datamover-internal-svc.yaml

sed -i 's/openstack/triliovault/' cert-triliovault-datamover-internal-svc.yaml
sed -i 's/openstack/triliovault/' cert-triliovault-datamover-public-svc.yaml

oc create -f cert-triliovault-datamover-public-svc.yaml
oc create -f cert-triliovault-datamover-internal-svc.yaml

oc describe secret cert-triliovault-datamover-public-svc
oc describe secret cert-triliovault-datamover-internal-svc
