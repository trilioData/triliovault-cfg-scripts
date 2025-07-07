#!/bin/bash

# Get a single consistent timestamp
RENEW_AT=$(date -Iseconds)

# Apply updated cert spec
oc -n openstack apply -f ./certificate.yaml

# Force renew all certs using the same timestamp
oc annotate certificate triliovault-wlm-public-svc \
  -n openstack cert-manager.io/renew-request-at="$RENEW_AT" --overwrite

oc annotate certificate triliovault-wlm-internal-svc \
  -n openstack cert-manager.io/renew-request-at="$RENEW_AT" --overwrite

oc annotate certificate triliovault-datamover-public-svc \
  -n openstack cert-manager.io/renew-request-at="$RENEW_AT" --overwrite

oc annotate certificate triliovault-datamover-internal-svc \
  -n openstack cert-manager.io/renew-request-at="$RENEW_AT" --overwrite


sleep 120s

echo -n "Certificate Validity for cert-triliovault-wlm-public-svc:"
oc get secret cert-triliovault-wlm-public-svc -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates


echo -n "Certificate Validity for cert-triliovault-wlm-internal-svc:"
oc get secret cert-triliovault-wlm-internal-svc -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates


echo -n "Certificate Validity for cert-triliovault-datamover-public-svc:"
oc get secret cert-triliovault-datamover-public-svc -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

echo -n "Certificate Validity for cert-triliovault-datamover-internal-svc "
oc get secret cert-triliovault-datamover-internal-svc  -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

sleep 10s


oc get secret cert-triliovault-wlm-public-svc -n openstack -o yaml > cert-triliovault-wlm-public-svc.yaml
oc get secret cert-triliovault-wlm-internal-svc -n openstack -o yaml > cert-triliovault-wlm-internal-svc.yaml

sed -i 's/openstack/trilio-openstack/' cert-triliovault-wlm-internal-svc.yaml
sed -i 's/openstack/trilio-openstack/' cert-triliovault-wlm-public-svc.yaml

oc apply -f cert-triliovault-wlm-public-svc.yaml
oc apply -f cert-triliovault-wlm-internal-svc.yaml

oc describe secret cert-triliovault-wlm-public-svc -n trilio-openstack
oc describe secret cert-triliovault-wlm-internal-svc -n trilio-openstack


oc get secret cert-triliovault-datamover-public-svc -n openstack -o yaml > cert-triliovault-datamover-public-svc.yaml
oc get secret cert-triliovault-datamover-internal-svc -n openstack -o yaml > cert-triliovault-datamover-internal-svc.yaml

sed -i 's/openstack/trilio-openstack/' cert-triliovault-datamover-internal-svc.yaml
sed -i 's/openstack/trilio-openstack/' cert-triliovault-datamover-public-svc.yaml

oc apply -f cert-triliovault-datamover-public-svc.yaml
oc apply -f cert-triliovault-datamover-internal-svc.yaml

oc describe secret cert-triliovault-datamover-public-svc -n trilio-openstack
oc describe secret cert-triliovault-datamover-internal-svc -n trilio-openstack

echo -n "Certificates renewed, please restart Trilio control plane pods."