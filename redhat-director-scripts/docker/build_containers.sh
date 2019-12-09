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

################## Build RHOSP14 containers ####################

## Work dir preparation for for rhosp14
build_dir=tmp_docker_rhosp14_${tvault_version}
rm -rf $base_dir/${build_dir}
mkdir -p $base_dir/${build_dir}

cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

#Build trilio-datamover containers for rhosp14

echo -e "Creating trilio-datamover container for rhosp14"
cd $base_dir/${build_dir}/trilio-datamover/
rm Dockerfile
cp Dockerfile_rhosp14 Dockerfile
docker build --no-cache -t docker.io/trilio/trilio-datamover:${tvault_version}-rhosp14 .
docker push docker.io/trilio/trilio-datamover:${tvault_version}-rhosp14



#Build trilio_datamover-api containers for rhosp14

echo -e "Creating trilio-datamover-api container for rhosp14"
cd $base_dir/${build_dir}/trilio-datamover-api/
rm Dockerfile
cp Dockerfile_rhosp14 Dockerfile
docker build --no-cache -t docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp14 .
docker push docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp14

## Build horizon plugin container for rhosp14

echo -e "Creating trilio horizon plugin container for rhosp14"
cd $base_dir/${build_dir}/trilio-horizon-plugin/
rm Dockerfile
cp Dockerfile_rhosp14 Dockerfile
docker build --no-cache -t docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp14 .
docker push docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp14

# Clean the build_dir
rm -rf $base_dir/${build_dir}

################## Build TripleO Rocky containers ####################

## Work dir preparation for for tripleorocky
build_dir=tmp_docker_tripleorocky_${tvault_version}
rm -rf $base_dir/${build_dir}
mkdir -p $base_dir/${build_dir}

cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

#Build trilio-datamover containers for Tripleo rocky

echo -e "Creating trilio-datamover container for Tripleo rocky"
cd $base_dir/${build_dir}/trilio-datamover/
rm Dockerfile
cp Dockerfile_tripleorocky Dockerfile
docker build --no-cache -t docker.io/trilio/trilio-datamover:${tvault_version}-tripleorocky .
docker push docker.io/trilio/trilio-datamover:${tvault_version}-tripleorocky



#Build trilio_datamover-api containers for tripleo rocky

echo -e "Creating trilio-datamover-api container for Tripleo rocky"
cd $base_dir/${build_dir}/trilio-datamover-api/
rm Dockerfile
cp Dockerfile_tripleorocky Dockerfile
docker build --no-cache -t docker.io/trilio/trilio-datamover-api:${tvault_version}-tripleorocky .
docker push docker.io/trilio/trilio-datamover-api:${tvault_version}-tripleorocky

## Build horizon plugin container for tripleo rocky

echo -e "Creating trilio horizon plugin container for Tripleo rocky"
cd $base_dir/${build_dir}/trilio-horizon-plugin/
rm Dockerfile
cp Dockerfile_tripleorocky Dockerfile
docker build --no-cache -t docker.io/trilio/trilio-horizon-plugin:${tvault_version}-tripleorocky .
docker push docker.io/trilio/trilio-horizon-plugin:${tvault_version}-tripleorocky

# Clean the build_dir
rm -rf $base_dir/${build_dir}


##################### Create containers for rhosp13 ################

build_dir=tmp_docker_${tvault_version}
rm -rf $base_dir/${build_dir}
mkdir -p $base_dir/${build_dir}
cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

##Build trilio-datamover containers

echo -e "Creating trilio-datamover container for rhosp13"
cd $base_dir/${build_dir}/trilio-datamover/
docker build --no-cache -t trilio/trilio-datamover:${tvault_version}-rhosp13 .

#Build trilio_datamover-api containers

echo -e "Creating trilio-datamover-api container for rhosp13"
cd $base_dir/${build_dir}/trilio-datamover-api/
docker build --no-cache -t trilio/trilio-datamover-api:${tvault_version}-rhosp13 .


## Build horizon plugin

echo -e "Creating trilio horizon plugin container for rhosp13"
cd $base_dir/${build_dir}/trilio-horizon-plugin/
docker build --no-cache -t trilio/trilio-horizon-plugin:${tvault_version}-rhosp13 .



# Clean the build_dir
rm -rf $base_dir/${build_dir}

#################################################################################################

################## Build RHOSP15 containers ####################

## Work dir preparation for for rhosp15
build_dir=tmp_docker_rhosp15_${tvault_version}
rm -rf $base_dir/${build_dir}
mkdir -p $base_dir/${build_dir}

cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

#Build trilio-datamover containers for rhosp15

echo -e "Creating trilio-datamover container for rhosp15"
cd $base_dir/${build_dir}/trilio-datamover/
rm Dockerfile
cp Dockerfile_rhosp15 Dockerfile
buildah bud -t docker.io/trilio/trilio-datamover:${tvault_version}-rhosp15 .
podman push docker.io/trilio/trilio-datamover:${tvault_version}-rhosp15



#Build trilio_datamover-api containers for rhosp15

echo -e "Creating trilio-datamover-api container for rhosp15"
cd $base_dir/${build_dir}/trilio-datamover-api/
rm Dockerfile
cp Dockerfile_rhosp15 Dockerfile
buildah bud -t docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp15 .
podman push docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp15

## Build horizon plugin container for rhosp15

echo -e "Creating trilio horizon plugin container for rhosp15"
cd $base_dir/${build_dir}/trilio-horizon-plugin/
rm Dockerfile
cp Dockerfile_rhosp15 Dockerfile
buildah bud -t docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp15 .
podman push docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp15

# Clean the build_dir
rm -rf $base_dir/${build_dir}

################# Create containers for RHOSP14 #######################
