#!/bin/bash

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 argument"
   echo -e "./prepare_trilio_images_dockerhub.sh <undercloud_ip> <container_tag(queens)>"
   exit 1
fi

undercloud_ip=$1
tag=$2

##Login to redhat container registry
#echo -e "Enter Redhat container registry credentials"
#docker login docker.io

## Prepare openstack horizon with trilio container
docker pull docker.io/trilio/trilio-horizon-plugin:${tag}
docker tag docker.io/trilio/trilio-horizon-plugin:${tag} ${undercloud_ip}:8787/trilio/trilio-horizon-plugin:${tag}
docker push ${undercloud_ip}:8787/trilio/trilio-horizon-plugin:${tag}

## Prepare trilio datamover container
docker pull docker.io/trilio/trilio-datamover:${tag}
docker tag docker.io/trilio/trilio-datamover:${tag} ${undercloud_ip}:8787/trilio/trilio-datamover:${tag}
docker push ${undercloud_ip}:8787/trilio/trilio-datamover:${tag}

## Prepare trilio datamover api container
docker pull docker.io/trilio/trilio-datamover-api:${tag}
docker tag docker.io/trilio/trilio-datamover-api:${tag} ${undercloud_ip}:8787/trilio/trilio-datamover-api:${tag}
docker push ${undercloud_ip}:8787/trilio/trilio-datamover-api:${tag}

## Update image locations in env file
dm_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover:${tag}"
dmapi_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover-api:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${dm_image_name}/g" trilio_env.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${dmapi_image_name}/g" trilio_env.yaml
