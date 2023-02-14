#!/bin/bash -x

set -e

echo -e "\nPREREQUISITES:\n\tPlease make sure that you logged in to docker.io and registry.redhat.io"
echo -e "\tdocker.io should be logged in with user having pull and push permissions to https://hub.docker.com/u/trilio/dashboard/"
echo -e "\tregistry.redhat.io registry login needs user with only pull permissions"
echo -e "\tYou can use following commands:"
echo -e "\n\t- podman login docker.io\n\t- podman login registry.redhat.io\n"


if [ $# -lt 4 ];then
   echo "Script takes exactly 4 arguments"
   echo -e "./build_rhosp16_containers.sh <tvault_version> <PUSH_PKG_CNT> <fury_organization> <containers_to_build>"
   exit 1
fi

tvault_version=$1
fury_repo=$(echo $3)
declare -a containers_to_build=($(echo $4))

current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
	base_dir="$current_dir"
else
        #Get absolute path of target dir
        base_dir=$current_dir/$base_dir
fi

declare -a openstack_releases=("rhosp16.1" "rhosp16.2")

declare -a rhosp_releases=("16.1" "16.2")

## now loop through the above array to build the containers
for openstack_release in "${openstack_releases[@]}"
do
      build_dir=tmp_docker_${openstack_release}
      rm -rf $base_dir/${build_dir}
      mkdir -p $base_dir/${build_dir}
      for container_to_build in "${containers_to_build[@]}"
      do
	cp -R $base_dir/${container_to_build} $base_dir/${build_dir}/
	echo -e "Creating ${container_to_build} container for ${openstack_release}"
	cd $base_dir/${build_dir}/${container_to_build}/

	sed -i "s/{VERSION}/${fury_repo}/g" trilio.repo
	cp Dockerfile_${openstack_release} Dockerfile
	buildah --authfile /root/redhat-auth.json bud --pull-always --format=oci -t docker.io/trilio/${container_to_build}:${tvault_version}-${openstack_release} .
	cd -
      done

      # Clean the build_dir
      rm -rf $base_dir/${build_dir}
done

## now loop through the above array to push the containers
for openstack_release in "${openstack_releases[@]}"
do
      for container_to_build in "${containers_to_build[@]}"
      do
	if [ $(echo "$PUSH_PKG_CNT" | tr '[:upper:]' '[:lower:]') == "yes" ]
	then
		echo "$PUSH_PKG_CNT : Push ${container_to_build} Containers to Docker"
		podman push --authfile /root/auth.json docker.io/trilio/${container_to_build}:${tvault_version}-${openstack_release}
	else
		echo "$PUSH_PKG_CNT : Don't push ${container_to_build} Containers to Docker"
	fi
      done
done
