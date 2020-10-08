#!/bin/bash

set -e

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 argument"
   echo -e "./prepare_trilio_images.sh <undercloud_ip> <container_tag(queens)>"
   exit 1
fi

undercloud_ip=$1
tag=$2

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

##Login to redhat container registry
echo -e "Enter Redhat container registry credentials"
docker login registry.connect.redhat.com

## Prepare openstack horizon with trilio container
docker pull registry.connect.redhat.com/trilio/trilio-horizon-plugin:${tag}
docker tag registry.connect.redhat.com/trilio/trilio-horizon-plugin:${tag} ${undercloud_ip}:8787/trilio/trilio-horizon-plugin:${tag}
docker push ${undercloud_ip}:8787/trilio/trilio-horizon-plugin:${tag}

## Prepare trilio datamover container
docker pull registry.connect.redhat.com/trilio/trilio-datamover:${tag}
docker tag registry.connect.redhat.com/trilio/trilio-datamover:${tag} ${undercloud_ip}:8787/trilio/trilio-datamover:${tag}
docker push ${undercloud_ip}:8787/trilio/trilio-datamover:${tag}

## Prepare trilio datamover api container
docker pull registry.connect.redhat.com/trilio/trilio-datamover-api:${tag}
docker tag registry.connect.redhat.com/trilio/trilio-datamover-api:${tag} ${undercloud_ip}:8787/trilio/trilio-datamover-api:${tag}
docker push ${undercloud_ip}:8787/trilio/trilio-datamover-api:${tag}

## Update image locations in env file
dm_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover:${tag}"
dmapi_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover-api:${tag}"
trilio_horizon_image="${undercloud_ip}:8787\/trilio\/trilio-horizon-plugin:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${dm_image_name}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${dmapi_image_name}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*DockerHorizonImage.*/   DockerHorizonImage: ${trilio_horizon_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml