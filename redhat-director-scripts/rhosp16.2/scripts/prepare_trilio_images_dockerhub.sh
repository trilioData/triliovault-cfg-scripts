#!/bin/bash

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 argument"
   echo -e "./prepare_trilio_images_podmanhub.sh <undercloud_hostname> <container_tag(queens)>"
   exit 1
fi

undercloud_hostname=$1
tag=$2

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source /home/stack/stackrc

##Login to redhat container registry
echo -e "Enter dockerhub account credentials"
podman login docker.io

## Prepare openstack horizon with trilio container
podman pull docker.io/trilio/trilio-horizon-plugin:${tag}
podman tag docker.io/trilio/trilio-horizon-plugin:${tag} ${undercloud_hostname}:8787/trilio/trilio-horizon-plugin:${tag}
openstack tripleo container image push --local ${undercloud_hostname}:8787/trilio/trilio-horizon-plugin:${tag}

## Prepare trilio datamover container
podman pull docker.io/trilio/trilio-datamover:${tag}
podman tag docker.io/trilio/trilio-datamover:${tag} ${undercloud_hostname}:8787/trilio/trilio-datamover:${tag}
openstack tripleo container image push --local ${undercloud_hostname}:8787/trilio/trilio-datamover:${tag}

## Prepare trilio datamover api container
podman pull docker.io/trilio/trilio-datamover-api:${tag}
podman tag docker.io/trilio/trilio-datamover-api:${tag} ${undercloud_hostname}:8787/trilio/trilio-datamover-api:${tag}
openstack tripleo container image push --local ${undercloud_hostname}:8787/trilio/trilio-datamover-api:${tag}


## Update image locations in env file
trilio_dm_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover:${tag}"
trilio_dmapi_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover-api:${tag}"
trilio_horizon_image="${undercloud_hostname}:8787\/trilio\/trilio-horizon-plugin:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${trilio_dm_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${trilio_dmapi_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*ContainerHorizonImage.*/   ContainerHorizonImage: ${trilio_horizon_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
