#!/bin/bash

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=$1


declare -a openstack_releases=("ussuri")

declare -a openstack_platforms=("centos" "ubuntu")

## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do

    for openstack_platform in "${openstack_platforms[@]}"
    do
        docker tag trilio/${openstack_platform}-binary-trilio-datamover-api:${tvault_version}-${openstack_release} \
        docker.io/trilio/${openstack_platform}-binary-trilio-datamover-api:${tvault_version}-${openstack_release}
        docker push docker.io/trilio/${openstack_platform}-binary-trilio-datamover-api:${tvault_version}-${openstack_release}

        docker tag trilio/${openstack_platform}-binary-trilio-datamover-api:${tvault_version}-${openstack_release} \
        docker.io/trilio/${openstack_platform}-binary-trilio-datamover-api:${tvault_version}-${openstack_release}
        docker push docker.io/trilio/${openstack_platform}-binary-trilio-datamover:${tvault_version}-${openstack_release}

      if [ "$openstack_release" == "ussuri" ]
      then
        docker tag trilio/${openstack_platform}-binary-trilio-horizon-plugin:${tvault_version}-${openstack_release} \
        docker.io/trilio/${openstack_platform}-binary-trilio-horizon-plugin:${tvault_version}-${openstack_release}
        docker push docker.io/trilio/${openstack_platform}-binary-trilio-horizon-plugin:${tvault_version}-${openstack_release}
      fi
    done
done
