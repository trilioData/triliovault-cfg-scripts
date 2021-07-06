#!/bin/bash

set -e

if [ $# -lt 3 ];then
   echo "Script takes exacyly 3 arguments"
   echo -e "./prepare_trilio_images.sh <undercloud_registry_hostname_or_ip> <OS_platform> <container_tag>"
   echo -e "For example:"
   echo -e "./prepare_trilio_images.sh undercloud.ctlplane.ooo.prod1 centos7 4.1.124"
   echo -e "Valid values for <OS_platform> are 'centos7' and 'centos8'"
   exit 1
fi

undercloud_hostname=$1
os_platform=$2
tag=$3

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

container_tool="docker"

if [ "$os_platform" == "centos7" ]
then
   container_tool="docker"
else
   container_tool="podman"
fi

source /home/stack/stackrc

##Login to redhat container registry
echo -e "Enter dockerhub account credentials"
${container_tool} login docker.io

container_prefix="tripleo-train-${os_platform}"
## Prepare openstack horizon with trilio container
${container_tool} pull docker.io/trilio/${container_prefix}-trilio-horizon-plugin:${tag}
${container_tool} tag docker.io/trilio/${container_prefix}-trilio-horizon-plugin:${tag} ${undercloud_hostname}:8787/trilio/${container_prefix}-trilio-horizon-plugin:${tag}
openstack tripleo container image push --local ${undercloud_hostname}:8787/trilio/${container_prefix}-trilio-horizon-plugin:${tag}

## Prepare trilio datamover container
${container_tool} pull docker.io/trilio/${container_prefix}-trilio-datamover:${tag}
${container_tool} tag docker.io/trilio/${container_prefix}-trilio-datamover:${tag} ${undercloud_hostname}:8787/trilio/${container_prefix}-trilio-datamover:${tag}
openstack tripleo container image push --local ${undercloud_hostname}:8787/trilio/${container_prefix}-trilio-datamover:${tag}

## Prepare trilio datamover api container
${container_tool} pull docker.io/trilio/${container_prefix}-trilio-datamover-api:${tag}
${container_tool} tag docker.io/trilio/${container_prefix}-trilio-datamover-api:${tag} ${undercloud_hostname}:8787/trilio/${container_prefix}-trilio-datamover-api:${tag}
openstack tripleo container image push --local ${undercloud_hostname}:8787/trilio/${container_prefix}-trilio-datamover-api:${tag}


## Update image locations in env file
trilio_dm_image="${undercloud_hostname}:8787\/trilio\/tripleo-train-${os_platform}-trilio-datamover:${tag}"
trilio_dmapi_image="${undercloud_hostname}:8787\/trilio\/tripleo-train-${os_platform}-trilio-datamover-api:${tag}"
trilio_horizon_image="${undercloud_hostname}:8787\/trilio\/tripleo-train-${os_platform}-trilio-horizon-plugin:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${trilio_dm_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${trilio_dmapi_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
sed  -i "s/.*ContainerHorizonImage.*/   ContainerHorizonImage: ${trilio_horizon_image}/g" $SCRIPT_DIR/../environments/trilio_env.yaml
