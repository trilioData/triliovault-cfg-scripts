#!/bin/bash



echo "Fetching current CoreDNS ConfigMap..."
kubectl -n kube-system get configmap coredns -o yaml > /tmp/coredns.yaml

# Check if the DNS entry already exists
if grep -q "192.168.0.100 cephquincy.triliodata.demo" /tmp/coredns.yaml; then
    echo "cephquincy.triliodata.demo already exists in CoreDNS ConfigMap."
    exit 0
fi

echo "Patching CoreDNS ConfigMap with Ceph S3 endpoint..."
# Use awk to inject the DNS entry safely inside the 'hosts {' block
awk '
/hosts \{/ {
    print
    print "           192.168.0.100 cephquincy.triliodata.demo"
    next
}
{ print }
' /tmp/coredns.yaml > /tmp/coredns-patched.yaml

# Apply the patched ConfigMap back to the cluster
kubectl -n kube-system apply -f /tmp/coredns-patched.yaml
echo "CoreDNS ConfigMap successfully patched. CoreDNS pods will automatically reload within a few seconds."
