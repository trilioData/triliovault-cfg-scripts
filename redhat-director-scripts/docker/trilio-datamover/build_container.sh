#!/bin/bash

if [ $# -lt 5 ];then
   echo "Script takes 5 arguments"
   exit 1
fi

tag=$2
name=$1
redhat_subscription_username=$3
redhat_subscription_password=$4
redhat_openStack_pool_id=$5

docker build \
--build-arg redhat_username=$redhat_subscription_username --build-arg redhat_password=$redhat_subscription_password \
--build-arg redhat_pool_id=$redhat_openStack_pool_id  -t $name:$tag .
