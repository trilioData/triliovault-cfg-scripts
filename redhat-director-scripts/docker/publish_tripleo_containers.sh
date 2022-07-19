#!/bin/bash

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=$1


openstack_distro="tripleo"

declare -a openstack_releases=("train")

declare -a openstack_platforms=("centos7")

## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do

    for openstack_platform in "${openstack_platforms[@]}"
    do
        container_prefix="${openstack_distro}-${openstack_release}-${openstack_platform}"
        #podman tag trilio/${container_prefix}-trilio-datamover-api:${tvault_version}-${openstack_distro} \
        #docker.io/trilio/${container_prefix}-trilio-datamover-api:${tvault_version}-${openstack_distro}
        #podman push --authfile /root/auth.json docker.io/trilio/${container_prefix}-trilio-datamover-api:${tvault_version}-${openstack_distro}

        #podman tag trilio/${container_prefix}-trilio-datamover:${tvault_version}-${openstack_distro} \
        #docker.io/trilio/${container_prefix}-trilio-datamover:${tvault_version}-${openstack_distro}
        #podman push --authfile /root/auth.json docker.io/trilio/${container_prefix}-trilio-datamover:${tvault_version}-${openstack_distro}

        podman tag trilio/${container_prefix}-trilio-horizon-plugin:${tvault_version}-${openstack_distro} \
        docker.io/trilio/${container_prefix}-trilio-horizon-plugin:${tvault_version}-${openstack_distro}
        podman push --authfile /root/auth.json docker.io/trilio/${container_prefix}-trilio-horizon-plugin:${tvault_version}-${openstack_distro}
    done
done
