#!/bin/bash

set -e

if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./prepare_trilio_images.sh <CONTAINER_TAG>"
   exit 1
fi

tag=$1


current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi

build_dir="/tmp/tmp_docker_rhosp16_${tvault_version}"
rm -rf ${build_dir}
mkdir -p ${build_dir}

cp -R $base_dir/docker/trilio-datamover ${build_dir}/
cp -R $base_dir/docker/trilio-datamover-api ${build_dir}/
cp -R $base_dir/docker/trilio-horizon-plugin ${build_dir}/


source /home/stack/stackrc

##Login to redhat container registry
echo -e "Enter Redhat container registry credentials"
podman login registry.redhat.io


# Pull containers. Pull from dockerfile while building teh container is having issue
podman pull registry.redhat.io/rhosp-rhel8/openstack-nova-compute:16.0
podman pull registry.redhat.io/rhosp-rhel8/openstack-nova-api:16.0
podman pull registry.redhat.io/rhosp-rhel8/openstack-horizon:16.0


#Build trilio-datamover containers for rhosp16

echo -e "Creating trilio-datamover container for rhosp16"
cd ${build_dir}/trilio-datamover/
rm Dockerfile
cp Dockerfile_rhosp16 Dockerfile
buildah bud --format docker -t docker.io/trilio/trilio-datamover:${tag} .
openstack tripleo container image push --local docker.io/trilio/trilio-datamover:${tag}



#Build trilio_datamover-api containers for rhosp16

echo -e "Creating trilio-datamover-api container for rhosp16"
cd ${build_dir}/trilio-datamover-api/
rm Dockerfile
cp Dockerfile_rhosp16 Dockerfile
buildah bud --format docker -t docker.io/trilio/trilio-datamover-api:${tag} .
openstack tripleo container image push --local docker.io/trilio/trilio-datamover-api:${tag}

## Build horizon plugin container for rhosp16

echo -e "Creating trilio horizon plugin container for rhosp16"
cd ${build_dir}/trilio-horizon-plugin/
rm Dockerfile
cp Dockerfile_rhosp16 Dockerfile
buildah bud --format docker -t docker.io/trilio/trilio-horizon-plugin:${tag} .
openstack tripleo container image push --local docker.io/trilio/trilio-horizon-plugin:${tag}

# Clean the build_dir
rm -rf ${build_dir}

## Prepare openstack horizon with trilio container
###podman pull registry.redhat.io/trilio/trilio-horizon-plugin:${tag}
###podman tag registry.redhat.io/trilio/trilio-horizon-plugin:${tag} ${undercloud_ip}:8787/trilio/trilio-horizon-plugin:${tag}
#openstack tripleo container image push --local ${undercloud_ip}:8787/trilio/trilio-horizon-plugin:${tag}

## Prepare trilio datamover container
###podman pull registry.redhat.io/trilio/trilio-datamover:${tag}
###podman tag registry.redhat.io/trilio/trilio-datamover:${tag} ${undercloud_ip}:8787/trilio/trilio-datamover:${tag}
#openstack tripleo container image push --local ${undercloud_ip}:8787/trilio/trilio-datamover:${tag}

## Prepare trilio datamover api container
###podman pull registry.redhat.io/trilio/trilio-datamover-api:${tag}
###pdoman tag registry.redhat.io/trilio/trilio-datamover-api:${tag} ${undercloud_ip}:8787/trilio/trilio-datamover-api:${tag}
#openstack tripleo container image push --local ${undercloud_ip}:8787/trilio/trilio-datamover-api:${tag}

## Update image locations in env file
dm_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover:${tag}"
dmapi_image_name="${undercloud_ip}:8787\/trilio\/trilio-datamover-api:${tag}"

sed  -i "s/.*DockerTrilioDatamoverImage.*/\   DockerTrilioDatamoverImage:\ ${dm_image_name}/g" trilio_env.yaml
sed  -i "s/.*DockerTrilioDmApiImage.*/   DockerTrilioDmApiImage: ${dmapi_image_name}/g" trilio_env.yaml
