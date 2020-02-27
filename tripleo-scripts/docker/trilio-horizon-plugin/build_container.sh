#!/bin/bash -x

set -e

if [ $# -ne 1 ];then
   echo -e "Script takes exactly 1 arguments\n"
   echo -e "./build_container.sh <container_tag>"
   echo -e "./build_container.sh test-3.4.1"
   exit 1
fi

tag=$1

docker build --no-cache -t trilio/trilio-horizon-plugin-tripleo:$tag .
docker push trilio/trilio-horizon-plugin-tripleo:$tag
