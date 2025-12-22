#!/bin/bash

set -e
echo -e "Applying certificate.yaml"

APPLY_OUTPUT=$(oc -n openstack apply -f ./certificate.yaml)
echo $APPLY_OUTPUT
TOTAL_LINES=$(echo "$APPLY_OUTPUT" | wc -l)
set +e
UNCHANGED_LINES=$(echo "$APPLY_OUTPUT" | grep -c 'unchanged')
set -e
if [ "$TOTAL_LINES" -eq "$UNCHANGED_LINES" ]; then
  echo -e "\nNo change detected in certificate.yaml"
else
  echo "Detected changes in certificate resources. Proceeding..."
  echo -e "\nWaiting for certificates to get renewed, script will continue after 60 seconds"
  sleep 60s
fi


oc delete secret cert-triliovault-wlm-internal-svc cert-triliovault-wlm-public-svc \
  cert-triliovault-datamover-internal-svc cert-triliovault-datamover-public-svc -n openstack

sleep 60s

echo -e "\nFollowing are the certificate validity dates. Please check if it looks good."
echo -e "\nCertificate Validity for cert-triliovault-wlm-public-svc:"
oc get secret cert-triliovault-wlm-public-svc -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates


echo -e "\nCertificate Validity for cert-triliovault-wlm-internal-svc:"
oc get secret cert-triliovault-wlm-internal-svc -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates


echo -e "\nCertificate Validity for cert-triliovault-datamover-public-svc:"
oc get secret cert-triliovault-datamover-public-svc -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

echo -e "\nCertificate Validity for cert-triliovault-datamover-internal-svc "
oc get secret cert-triliovault-datamover-internal-svc  -n openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates


echo -e "\n\nIn the above output, if any of the certificate validity dates does not look okay to you then you can stop script here using key ctrl + c"
echo -e "Script will continue after 30 seconds"
sleep 30s


echo -e "\nCopying cert secrets to trilio-openstack namespace"
oc get secret cert-triliovault-wlm-public-svc -n openstack -o yaml > cert-triliovault-wlm-public-svc.yaml
oc get secret cert-triliovault-wlm-internal-svc -n openstack -o yaml > cert-triliovault-wlm-internal-svc.yaml

sed -i 's/openstack/trilio-openstack/' cert-triliovault-wlm-internal-svc.yaml
sed -i 's/openstack/trilio-openstack/' cert-triliovault-wlm-public-svc.yaml

oc -n trilio-openstack delete secret cert-triliovault-wlm-public-svc 
oc -n trilio-openstack apply -f cert-triliovault-wlm-public-svc.yaml

oc -n trilio-openstack delete secret cert-triliovault-wlm-internal-svc
oc -n trilio-openstack apply -f cert-triliovault-wlm-internal-svc.yaml

oc describe secret cert-triliovault-wlm-public-svc -n trilio-openstack
oc describe secret cert-triliovault-wlm-internal-svc -n trilio-openstack


oc get secret cert-triliovault-datamover-public-svc -n openstack -o yaml > cert-triliovault-datamover-public-svc.yaml
oc get secret cert-triliovault-datamover-internal-svc -n openstack -o yaml > cert-triliovault-datamover-internal-svc.yaml

sed -i 's/openstack/trilio-openstack/' cert-triliovault-datamover-internal-svc.yaml
sed -i 's/openstack/trilio-openstack/' cert-triliovault-datamover-public-svc.yaml

oc -n trilio-openstack delete secret cert-triliovault-datamover-public-svc
oc -n trilio-openstack apply -f cert-triliovault-datamover-public-svc.yaml

oc -n trilio-openstack delete secret cert-triliovault-datamover-internal-svc
oc -n trilio-openstack apply -f cert-triliovault-datamover-internal-svc.yaml

oc describe secret cert-triliovault-datamover-public-svc -n trilio-openstack
oc describe secret cert-triliovault-datamover-internal-svc -n trilio-openstack



oc get secret cert-trilio-rabbitmq-cluster -n openstack -o yaml > cert-trilio-rabbitmq-cluster.yaml
sed -i 's/openstack/trilio-openstack/' cert-trilio-rabbitmq-cluster.yaml
oc -n trilio-openstack delete secret cert-trilio-rabbitmq-cluster
oc apply -f cert-trilio-rabbitmq-cluster.yaml
oc describe secret cert-trilio-rabbitmq-cluster -n trilio-openstack



## Rabbitmq certs
oc get secret cert-trilio-rabbitmq-cluster -n openstack -o yaml > cert-trilio-rabbitmq-cluster.yaml
oc delete secret cert-trilio-rabbitmq-cluster -n trilio-openstack
sed -i 's/openstack/trilio-openstack/' cert-trilio-rabbitmq-cluster.yaml
oc apply -f cert-trilio-rabbitmq-cluster.yaml
oc describe secret cert-trilio-rabbitmq-cluster -n trilio-openstack



## Galera DB certs
oc get secret cert-trilio-galera-cluster -n openstack -o yaml > cert-trilio-galera-cluster.yaml
oc delete secret cert-trilio-galera-cluster -n trilio-openstack
sed -i 's/openstack/trilio-openstack/' cert-trilio-galera-cluster.yaml
oc apply -f cert-trilio-galera-cluster.yaml
oc describe secret cert-trilio-galera-cluster -n trilio-openstack




echo -e "\n\nCertificates renewed"

echo -e "\nNow restarting trilio control plane pods"
oc -n trilio-openstack rollout restart deployment triliovault-datamover-api triliovault-wlm-api triliovault-wlm-cron triliovault-wlm-scheduler triliovault-wlm-workloads

oc rollout status deployment/triliovault-datamover-api -n trilio-openstack --timeout=180s
oc rollout status deployment/triliovault-wlm-api -n trilio-openstack --timeout=180s
oc rollout status deployment/triliovault-wlm-cron -n trilio-openstack --timeout=180s
oc rollout status deployment/triliovault-wlm-scheduler -n trilio-openstack --timeout=180s
oc rollout status deployment/triliovault-wlm-workloads -n trilio-openstack --timeout=180s

sleep 30s
oc -n trilio-openstack get pods
echo -e "\nTrilio control plane pods are up and running with new certificates"
echo -e "\n Please ignore any pods in 'Terminating' state"

echo -e "\nFinal check on certificate validity dates"

echo -n "\nCertificate Validity for cert-triliovault-wlm-public-svc:"
oc get secret cert-triliovault-wlm-public-svc -n trilio-openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates


echo -n "\nCertificate Validity for cert-triliovault-wlm-internal-svc:"
oc get secret cert-triliovault-wlm-internal-svc -n trilio-openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates


echo -n "\nCertificate Validity for cert-triliovault-datamover-public-svc:"
oc get secret cert-triliovault-datamover-public-svc -n trilio-openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

echo -n "\nCertificate Validity for cert-triliovault-datamover-internal-svc "
oc get secret cert-triliovault-datamover-internal-svc  -n trilio-openstack -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

