!/bin/bash -x

set -e 

# Check if TAG argument is provided
if [ -z "$1" ]; then
  echo -e "Error: Pass TAG command line argument"
  echo -e "Example:   ./publish.sh stable-2"
  exit 1
fi


TAG=$1

podman push docker.io/trilio/rhoso-ansible-runner:$TAG
