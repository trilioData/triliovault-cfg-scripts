#!/bin/bash -x

set -e 

# Check if TAG argument is provided
if [ -z "$1" ]; then
  echo -e "Error: Pass TAG command line argument"
  echo -e "Example:   ./build.sh stable-2"
  exit 1
fi


TAG=$1


rm -rf edpm-ansible/
git clone https://github.com/openstack-k8s-operators/edpm-ansible.git
cp Dockerfile_ansible_runner edpm-ansible/
cp -R ../ansible-roles edpm-ansible/

cd edpm-ansible/
buildah bud -t docker.io/trilio/rhoso-ansible-runner:$TAG -f Dockerfile_ansible_runner .
podman push docker.io/trilio/rhoso-ansible-runner:$TAG
