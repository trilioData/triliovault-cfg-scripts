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

declare -a openstack_releases=("queens" "rocky" "stein")

declare -a openstack_platforms=("centos" "ubuntu")

## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
    for openstack_platform in "${openstack_platforms[@]}"
    do

		build_dir=tmp_docker_${openstack_release}_${openstack_platform}

        	mkdir -p $base_dir/${build_dir}
		cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
		cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/

		#Build trilio-datamover containers
		echo -e "Creating trilio-datamover container for kolla ${openstack_release} ${openstack_platform}"
		cd $base_dir/${build_dir}/trilio-datamover/
		mv Dockerfile_${openstack_release}_${openstack_platform} Dockerfile
		docker build --no-cache -t trilio/${openstack_platform}-source-trilio-datamover:${tvault_version}-${openstack_release} .


		#Build trilio_datamover-api containers
		echo -e "Creating trilio-datamover container-api for kolla ${openstack_release} ${openstack_platform}"
		cd $base_dir/${build_dir}/trilio-datamover-api/
		mv Dockerfile_${openstack_release}_${openstack_platform} Dockerfile
		docker build --no-cache -t trilio/${openstack_platform}-source-trilio-datamover-api:${tvault_version}-${openstack_release} .

		# Clean the build_dir
		rm -rf $base_dir/${build_dir}

    done
done
