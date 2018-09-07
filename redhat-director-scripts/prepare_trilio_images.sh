#!/bin/bash

if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./prepare_trilio_images.sh <undercloud_ip>"
   exit 1
fi

undercloud_ip=$1

## Prepare openstack horizon with trilio container
docker pull docker.io/trilio/openstack-horizon-with-trilio-plugin:queens
docker tag docker.io/trilio/openstack-horizon-with-trilio-plugin:ditest ${undercloud_ip}:8787/trilio/openstack-horizon-with-trilio-plugin:queens
docker push ${undercloud_ip}:8787/trilio/openstack-horizon-with-trilio-plugin:queens

## Prepare trilio datamover container
docker pull docker.io/trilio/trilio-datamover:queens
docker tag docker.io/trilio/trilio-datamover:queens ${undercloud_ip}:8787/trilio/trilio-datamover:queens
docker push ${undercloud_ip}:8787/trilio/trilio-datamover:queens

## Prepare trilio datamover api container
docker pull docker.io/trilio/trilio-datamover-api:queens
docker tag docker.io/trilio/trilio-datamover-api:queens ${undercloud_ip}:8787/trilio/trilio-datamover-api:queens
docker push ${undercloud_ip}:8787/trilio/trilio-datamover-api:queens
