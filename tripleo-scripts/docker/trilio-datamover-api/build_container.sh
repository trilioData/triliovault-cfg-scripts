#!/bin/bash

set -e

if [ $# -ne 1 ];then
   echo -e "Script takes exactly 1 argument\n"
   echo -e "./build_container.sh <container_tag>"
   echo -e "./build_container.sh queens"
   exit 1
fi

tag=$1

docker build --no-cache -t docker.io/trilio/trilio-datamover-api-tripleo:$tag .
docker push docker.io/trilio/trilio-datamover-api-tripleo:$tag
