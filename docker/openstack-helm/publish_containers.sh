#!/bin/bash -x

set -e

if [ $# -lt 3 ];then
   echo "Script takes exactly 3 argument"
   echo -e "./publish_container.sh <tvault_version> <openstack_releases> <containers_to_build>"
   exit 1
fi

tvault_version=$(echo $1)
declare -a openstack_releases=($(echo $2))
openstack_platform="ubuntu"
declare -a containers_to_build=($(echo $3))

## now loop through the openstack releases
for openstack_release in "${openstack_releases[@]}"
do
	tag=${tvault_version}
  
	for container_to_build in "${containers_to_build[@]}"
	do
		echo -e "Publishing ${container_to_build} container for openstack helm ${container_to_build}-helm:${tag}-${openstack_release}"
		docker tag trilio/${container_to_build}-helm:${tag}-${openstack_release} \
			docker.io/trilio/${container_to_build}-helm:${tag}-${openstack_release}
		docker push docker.io/trilio/${container_to_build}-helm:${tag}-${openstack_release}
	done
done
