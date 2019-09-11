#!/bin/bash -x

set -e

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

build_dir=tmp_docker_${tvault_version}
rm -rf $base_dir/${build_dir}
mkdir -p $base_dir/${build_dir}
cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

#Build trilio-datamover containers

echo -e "Creating trilio-datamover container for rhosp13"
cd $base_dir/${build_dir}/trilio-datamover/
docker build --no-cache -t trilio/trilio-datamover:${tvault_version} .

#Build trilio_datamover-api containers

echo -e "Creating trilio-datamover container-api for rhosp13"
cd $base_dir/${build_dir}/trilio-datamover-api/
docker build --no-cache -t trilio/trilio-datamover-api:${tvault_version} .


## Build horizon plugin

echo -e "Creating trilio horizon plugin container for rhosp13"
cd $base_dir/${build_dir}/trilio-horizon-plugin/
docker build --no-cache -t trilio/trilio-horizon-plugin:${tvault_version} .



# Clean the build_dir
rm -rf $base_dir/${build_dir}
