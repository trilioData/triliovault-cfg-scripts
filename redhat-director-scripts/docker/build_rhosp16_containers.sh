#!/bin/bash

set -e

echo -e "\nPREREQUISITES:\n\tPlease make sure that you logged in to docker.io and registry.redhat.io"
echo -e "\tdocker.io should be logged in with user having pull and push permissions to https://hub.docker.com/u/trilio/dashboard/"
echo -e "\tregistry.redhat.io registry login needs user with only pull permissions"
echo -e "\tYou can use following commands:"
echo -e "\n\t- podman login docker.io\n\t- podman login registry.redhat.io\n"


if [ $# -lt 1 ];then
   echo "Script takes exactly 1 argument"
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

declare -a openstack_releases=("rhosp16" "rhosp16.1" "rhosp16.2")

declare -a rhosp_releases=("16.0" "16.1" "16.2")

declare -a repositories=("registry.redhat.io/rhosp-rhel8/openstack-base" "registry.redhat.io/rhosp-rhel8/openstack-nova-compute" "registry.redhat.io/rhosp-rhel8/openstack-nova-api" "registry.redhat.io/rhosp-rhel8/openstack-horizon")

for rhosp_release in "${rhosp_releases[@]}"
do
      for repository in "${repositories[@]}"
      do
    	     podman pull --authfile /root/redhat-auth.json ${repository}:${rhosp_release}
      done
done

## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
      build_dir=tmp_docker_${openstack_release}
      rm -rf $base_dir/${build_dir}
      mkdir -p $base_dir/${build_dir}
      cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
      cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
      cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

      #Build trilio-datamover containers
      echo -e "Creating trilio-datamover container for ${openstack_release}"
      cd $base_dir/${build_dir}/trilio-datamover/
      cp Dockerfile_${openstack_release} Dockerfile
      buildah bud --format docker -t docker.io/trilio/trilio-datamover:${tvault_version}-${openstack_release} .
      if [ $(echo "$PUSH_PKG_CNT" | tr '[:upper:]' '[:lower:]') == "yes" ]
      then
          echo "$PUSH_PKG_CNT : Push Datamover Containers to Docker"
	  podman push --authfile /root/auth.json docker.io/trilio/trilio-datamover:${tvault_version}-${openstack_release}
      else
          echo "$PUSH_PKG_CNT : Don't push Datamover Containers to Docker"
      fi

      #Build trilio_datamover-api containers
      echo -e "Creating trilio-datamover container-api for ${openstack_release}"
      cd $base_dir/${build_dir}/trilio-datamover-api/
      cp Dockerfile_${openstack_release} Dockerfile
      buildah bud --format docker -t docker.io/trilio/trilio-datamover-api:${tvault_version}-${openstack_release} .
      if [ $(echo "$PUSH_PKG_CNT" | tr '[:upper:]' '[:lower:]') == "yes" ]
      then
          echo "$PUSH_PKG_CNT : Push Datamover API Containers to Docker"
	  podman push --authfile /root/auth.json docker.io/trilio/trilio-datamover-api:${tvault_version}-${openstack_release}
      else
          echo "$PUSH_PKG_CNT : Don't push Datamover API Containers to Docker"
      fi

      #Build trilio_horizon_plugin containers
      echo -e "Creating trilio-horizon-plugin container for ${openstack_release}"
      cd $base_dir/${build_dir}/trilio-horizon-plugin/
      cp Dockerfile_${openstack_release} Dockerfile
      buildah bud --format docker -t docker.io/trilio/trilio-horizon-plugin:${tvault_version}-${openstack_release} .
      if [ $(echo "$PUSH_PKG_CNT" | tr '[:upper:]' '[:lower:]') == "yes" ]
      then
          echo "$PUSH_PKG_CNT : Push Horizon Containers to Docker"
          podman push --authfile /root/auth.json  docker.io/trilio/trilio-horizon-plugin:${tvault_version}-${openstack_release}
      else
          echo "$PUSH_PKG_CNT : Don't push Horizon Containers to Docker"
      fi

      # Clean the build_dir
      rm -rf $base_dir/${build_dir}

done

