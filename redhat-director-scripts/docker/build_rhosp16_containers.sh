#!/bin/bash

set -e

echo -e "\nPREREQUISITES:\n\tPlease make sure that you logged in to docker.io and registry.redhat.io"
echo -e "\tdocker.io should be logged in with user having pull and push permissions to https://hub.docker.com/u/trilio/dashboard/"
echo -e "\tregistry.redhat.io registry login needs user with only pull permissions"
echo -e "\tYou can use following commands:"
echo -e "\n\t- docker login docker.io\n\t- docker login registry.redhat.io\n\t- podman login docker.io\n\t- podman login registry.redhat.io\n"


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=$1


current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi

#declare -a openstack_releases=("rhosp13")

#declare -a openstack_platforms=("centos" "ubuntu")

################# Create containers for RHOSP16 #######################
## Work dir preparation for for rhosp16
build_dir=tmp_docker_rhosp16_${tvault_version}
rm -rf $base_dir/${build_dir}
mkdir -p $base_dir/${build_dir}

cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

#Build trilio-datamover containers for rhosp16

echo -e "Creating trilio-datamover container for rhosp16"
cd $base_dir/${build_dir}/trilio-datamover/
rm Dockerfile
cp Dockerfile_rhosp16 Dockerfile
buildah bud --format docker -t docker.io/trilio/trilio-datamover:${tvault_version}-rhosp16 .
podman push docker.io/trilio/trilio-datamover:${tvault_version}-rhosp16


#Build trilio_datamover-api containers for rhosp16

echo -e "Creating trilio-datamover-api container for rhosp16"
cd $base_dir/${build_dir}/trilio-datamover-api/
rm Dockerfile
cp Dockerfile_rhosp16 Dockerfile
buildah bud --format docker -t docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp16 .
podman push docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp16

## Build horizon plugin container for rhosp16

echo -e "Creating trilio horizon plugin container for rhosp16"
cd $base_dir/${build_dir}/trilio-horizon-plugin/
rm Dockerfile
cp Dockerfile_rhosp16 Dockerfile
buildah bud --format docker -t docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp16 .
podman push docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp16

# Clean the build_dir
rm -rf $base_dir/${build_dir}
#########################################################################





