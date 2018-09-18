#!/bin/bash

set -e

if [ $# -lt 5 ];then
   echo "Script takes exacyly 5 arguments"
   echo -e "./build_container.sh <container_name> <container_tag> <redhat_subscription_username> <redhat_subscription_password> <redhat_openStack_pool_id>"
   exit 1
fi

name=$1
tag=$2
redhat_subscription_username=$3
redhat_subscription_password=$4
redhat_openStack_pool_id=$5

docker build --no-cache \
--build-arg redhat_username=$redhat_subscription_username --build-arg redhat_password=$redhat_subscription_password \
--build-arg redhat_pool_id=$redhat_openStack_pool_id -t $name:$tag .

docker push $name:$tag
