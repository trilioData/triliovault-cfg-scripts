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

##Login to redhat container registry
echo -e "Enter Redhat container registry credentials (registry.redhat.io)"
podman login registry.connect.redhat.com
podman pull registry.connect.redhat.com/trilio/trilio-horizon-plugin:${tag}
podman pull registry.connect.redhat.com/trilio/trilio-datamover:${tag}
podman pull registry.connect.redhat.com/trilio/trilio-datamover-api:${tag}
podman pull registry.connect.redhat.com/trilio/trilio-wlm:${tag}

openstack tripleo container image push --local registry.connect.redhat.com/trilio/trilio-datamover:${tag}

openstack tripleo container image push --local registry.connect.redhat.com/trilio/trilio-datamover-api:${tag}

openstack tripleo container image push --local registry.connect.redhat.com/trilio/trilio-wlm:${tag}

openstack tripleo container image push --local registry.connect.redhat.com/trilio/trilio-horizon-plugin:${tag}


## Update image locations in env file
trilio_dm_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover:${tag}"
trilio_dmapi_image="${undercloud_hostname}:8787\/trilio\/trilio-datamover-api:${tag}"
trilio_wlmapi_image="${undercloud_hostname}:8787\/trilio\/trilio-wlm:${tag}"
trilio_horizon_image="${undercloud_hostname}:8787\/trilio\/trilio-horizon-plugin:${tag}"

sed  -i "s/.*ContainerTriliovaultDatamoverImage.*/\   ContainerTriliovaultDatamoverImage:\ ${trilio_dm_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*ContainerTriliovaultDatamoverApiImage.*/   ContainerTriliovaultDatamoverApiImage: ${trilio_dmapi_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*ContainerTriliovaultWlmImage.*/   ContainerTriliovaultWlmImage: ${trilio_wlmapi_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*ContainerHorizonImage.*/   ContainerHorizonImage: ${trilio_horizon_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
