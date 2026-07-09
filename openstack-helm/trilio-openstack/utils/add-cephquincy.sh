#!/bin/bash

# Default values (can be overridden via environment variables or arguments)
DNS_IP=${1:-"192.168.0.100"}
DNS_HOSTNAME=${2:-"cephquincy.triliodata.demo"}

echo "Fetching current CoreDNS ConfigMap..."
kubectl -n kube-system get configmap coredns -o yaml > /tmp/coredns.yaml

# Check if the DNS entry already exists
if grep -q "${DNS_IP} ${DNS_HOSTNAME}" /tmp/coredns.yaml; then
    echo "${DNS_HOSTNAME} already exists in CoreDNS ConfigMap."
    exit 0
fi

echo "Patching CoreDNS ConfigMap with Ceph S3 endpoint (${DNS_IP} ${DNS_HOSTNAME})..."
# Use awk to inject the DNS entry safely inside the 'hosts {' block
awk -v ip="${DNS_IP}" -v host="${DNS_HOSTNAME}" '
/hosts \{/ {
    print
    print "           " ip " " host
    next
}
{ print }
' /tmp/coredns.yaml > /tmp/coredns-patched.yaml

# Apply the patched ConfigMap back to the cluster
kubectl -n kube-system apply -f /tmp/coredns-patched.yaml
echo "CoreDNS ConfigMap successfully patched. CoreDNS pods will automatically reload within a few seconds."
