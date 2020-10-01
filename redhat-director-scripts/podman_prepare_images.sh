#!/bin/bash

set -e

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 argument"
   echo -e "./prepare_trilio_images.sh <UNDERCLOUD_REGISTRY_HOSTNAME> <CONTAINER_TAG>"
   exit 1
fi

undercloud_hostname=$1
tag=$2


current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi

source /home/stack/stackrc

##Login to redhat container registry
echo -e "Enter Redhat container registry credentials (registry.redhat.io)"
podman login registry.connect.redhat.com
podman pull registry.connect.redhat.com/trilio/trilio-horizon-plugin:${tag}
podman pull registry.connect.redhat.com/trilio/trilio-datamover:${tag}
podman pull registry.connect.redhat.com/trilio/trilio-datamover-api:${tag}

openstack tripleo container image push --local registry.connect.redhat.com/trilio/trilio-datamover:${tag}

openstack tripleo container image push --local registry.connect.redhat.com/trilio/trilio-datamover-api:${tag}

openstack tripleo container image push --local registry.connect.redhat.com/trilio/trilio-horizon-plugin:${tag}


## Update image locations in env file
trilio_dm_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover:${tag}"
trilio_dmapi_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover-api:${tag}"
trilio_horizon_image="${undercloud_hostname}:8787\/trilio\/trilio-horizon-plugin:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${trilio_dm_image}/g" trilio_env_osp16.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${trilio_dmapi_image}/g" trilio_env_osp16.yaml
sed  -i "s/.*ContainerHorizonImage.*/   ContainerHorizonImage: ${trilio_horizon_image}/g" trilio_env_osp16.yaml
