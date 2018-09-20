#!/bin/bash

set -e

if [ $# -lt 2 ];then
   echo "Script takes exacyly 5 arguments"
   echo -e "./build_container.sh <container_name> <container_tag>"
   exit 1
fi

name=$1
tag=$2
docker build --no-cache -t $name:$tag .
docker push $name:$tag
