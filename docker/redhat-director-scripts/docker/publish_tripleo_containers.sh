#!/bin/bash -x

set -e

if [ $# -lt 2 ];then
   echo "Script takes exactly 2 arguments"
   echo -e "./publish_container.sh <tvault_version> <containers_to_build>"
   exit 1
fi

tvault_version=$1


openstack_distro="tripleo"

declare -a openstack_releases=("train")
#Commenting for 4.2.HF2 only
#declare -a openstack_releases=("train" "wallaby")

declare -a openstack_platforms=("centos7")
#Commenting for 4.2.HF2 only
#declare -a openstack_platforms=("centos7" "centos8s")
declare -a containers_to_build=($(echo $3))

count=0
## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
    for openstack_platform in "${openstack_platforms[@]}"
    do
        container_prefix="${openstack_distro}-${openstack_release}-${openstack_platform}"
	for container_to_build in "${containers_to_build[@]}"
	do
        	podman tag trilio/${container_prefix}-${container_to_build}:${tvault_version}-${openstack_distro} \
	        docker.io/trilio/${container_prefix}-${container_to_build}:${tvault_version}-${openstack_distro}
	        podman push --authfile /root/auth.json docker.io/trilio/${container_prefix}-${container_to_build}:${tvault_version}-${openstack_distro}
	done
    done
done
