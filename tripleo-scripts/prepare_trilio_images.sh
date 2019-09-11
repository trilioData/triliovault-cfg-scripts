#!/bin/bash

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 argument"
   echo -e "./prepare_trilio_images.sh <undercloud_ip> <container_tag(queens)>"
   exit 1
fi

undercloud_ip=$1
tag=$2

registry_url="docker.io"
dm_container_name="trilio/trilio-datamover-tripleo"
dmapi_container_name="trilio/trilio-datamover-api-tripleo"
horizon_container_name="trilio/trilio-horizon-plugin-tripleo"

##Login to redhat container registry
echo -e "Enter Redhat container registry credentials"
docker login docker.io 

## Prepare openstack horizon with trilio container
docker pull ${registry_url}/${horizon_container_name}:${tag}
docker tag ${registry_url}/${horizon_container_name}:${tag} ${undercloud_ip}:8787/${horizon_container_name}:${tag}
docker push ${undercloud_ip}:8787/${horizon_container_name}:${tag}

## Prepare trilio datamover container
docker pull ${registry_url}/${dm_container_name}:${tag}
docker tag ${registry_url}/${dm_container_name}:${tag} ${undercloud_ip}:8787/${dm_container_name}:${tag}
docker push ${undercloud_ip}:8787/${dm_container_name}:${tag}

## Prepare trilio datamover api container
docker pull ${registry_url}/${dmapi_container_name}:${tag}
docker tag ${registry_url}/${dmapi_container_name}:${tag} ${undercloud_ip}:8787/${dmapi_container_name}:${tag}
docker push ${undercloud_ip}:8787/${dmapi_container_name}:${tag}

## Update image locations in env file
dm_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover-tripleo:${tag}"
dmapi_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover-api-tripleo:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${dm_image_name}/g" trilio_env.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${dmapi_image_name}/g" trilio_env.yaml
