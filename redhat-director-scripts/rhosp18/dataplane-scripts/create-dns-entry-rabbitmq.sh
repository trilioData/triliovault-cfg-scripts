#!/bin/bash
set -e

LB_IP=$(oc get svc trilio-rabbitmq-lb -n trilio-openstack -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

sed "s/<TRILIO-RABBITMQ-LB-SERVICE-IP>/$LB_IP/" dns-rabbitmq.yaml > rabbitmq-dns.yaml

oc -n openstack apply -f rabbitmq-dns.yaml

echo "DNSData created with IP: $LB_IP"