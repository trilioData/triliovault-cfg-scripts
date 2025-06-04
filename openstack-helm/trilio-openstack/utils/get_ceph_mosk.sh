#!/bin/bash -x

set -e


NOVA_CEPH_KEYRING=$(kubectl -n openstack get secrets/nova-rbd-keyring  --template={{.data.key}} | base64 -d)
kubectl -n openstack get secret libvirt-etc -o jsonpath='{.data.ceph\.conf}' | base64 -d > ../templates/bin/_triliovault-ceph.conf.tpl

cd ../

tee > values_overrides/ceph.yaml  << EOF
ceph:
  enabled: true
  rbd_user: nova
  keyring: $NOVA_CEPH_KEYRING
EOF

echo -e "Output is written to file ../values_overrides/ceph.yaml"
