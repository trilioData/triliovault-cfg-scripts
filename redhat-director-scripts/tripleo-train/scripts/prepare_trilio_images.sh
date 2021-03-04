#!/bin/bash

set -e

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 argument"
   echo -e "./prepare_trilio_images.sh <UNDERCLOUD_REGISTRY_HOSTNAME> <CONTAINER_TAG>"
   exit 1
fi

undercloud_hostname=$1
tag=$2

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi

source /home/stack/stackrc

trilio_registry="docker.io"

trilio_datamover_image_name="trilio-datamover-tripleo"
trilio_datamover_api_image_name="trilio-datamover-api-tripleo"
trilio_horizon_plugin_image_name="trilio-horizon-plugin-tripleo"


##Login to redhat container registry
echo -e "Enter trilio dockerhub credentials (Check with Trilio Team)"
podman login ${trilio_registry}
podman pull ${trilio_registry}/trilio/${trilio_horizon_plugin_image_name}:${tag}
podman pull ${trilio_registry}/trilio/${trilio_datamover_image_name}:${tag}
podman pull ${trilio_registry}/trilio/${trilio_datamover_api_image_name}:${tag}

openstack tripleo container image push --local ${trilio_registry}/trilio/${trilio_datamover_image_name}:${tag}

openstack tripleo container image push --local ${trilio_registry}/trilio/${trilio_datamover_api_image_name}:${tag}

openstack tripleo container image push --local ${trilio_registry}/trilio/${trilio_horizon_plugin_image_name}:${tag}


## Update image locations in env file
trilio_dm_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover-tripleo:${tag}"
trilio_dmapi_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover-api-tripleo:${tag}"
trilio_horizon_image="${undercloud_hostname}:8787\/trilio\/trilio-horizon-plugin-tripleo:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${trilio_dm_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${trilio_dmapi_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*ContainerHorizonImage.*/   ContainerHorizonImage: ${trilio_horizon_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
