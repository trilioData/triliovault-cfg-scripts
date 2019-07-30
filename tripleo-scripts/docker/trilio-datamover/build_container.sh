#!/bin/bash

set -e

if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <container_tag>"
   exit 1
fi

tag=$1
docker build --no-cache -t docker.io/trilio/trilio-datamover-tripleo:$tag .
docker push docker.io/trilio/trilio-datamover-tripleo:$tag
