#!/bin/bash -x

## Install CRD
if [ $# -lt 1 ];then
   echo "Script takes exactly 1 argument"
   echo -e "./install_operator.sh <TVO_OPERATOR_DOCKER_IMAGE_TAG>"
   exit 1
fi

IMAGE_TAG=$1

cd ../operator/tvo-operator/
make install

## Install Operator
export IMG=docker.io/trilio/tvo-operator:${IMAGE_TAG}
make deploy IMG=$IMG
