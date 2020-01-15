#!/bin/bash

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=$1


declare -a openstack_releases=("queens" "rocky" "stein" "train")


## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
    docker push trilio/centos-source-trilio-datamover-api:${tvault_version}-${openstack_release}
    docker push trilio/ubuntu-source-trilio-datamover-api:${tvault_version}-${openstack_release}
    docker push trilio/centos-source-trilio-datamover:${tvault_version}-${openstack_release}
    docker push trilio/ubuntu-source-trilio-datamover:${tvault_version}-${openstack_release}

done
