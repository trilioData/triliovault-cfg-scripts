#!/bin/bash -x

set -e


CINDER_CEPH_KEYRING=$(kubectl -n openstack get secrets/cinder-volume-rbd-keyring --template={{.data.key}} | base64 -d)
kubectl -n openstack get secret cinder-etc -o jsonpath='{.data.cinder\.conf}' | base64 -d > ../templates/bin/_triliovault-ceph.conf.tpl

cd ../

tee > values_overrides/ceph.yaml  << EOF
ceph:
  enabled: true
  rbd_user: cinder
  keyring: $CINDER_CEPH_KEYRING
EOF

echo -e "Output is written to file ../values_overrides/ceph.yaml"
