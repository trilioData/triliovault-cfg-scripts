#!/bin/bash

set -ex

# Check if TAG argument is provided
if [ -z "$1" ]; then
  echo "Error: TAG argument is required."
  exit 1
fi

# Assign the first argument to TAG variable
TAG=$1

cd ../operator/tvo-operator
export IMG=docker.io/trilio/tvo-operator:$TAG
make docker-push IMG=$IMG

