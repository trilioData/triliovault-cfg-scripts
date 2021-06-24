#!/bin/bash

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=($(echo $1| tr "," " "))

declare -a openstack_releases=($(echo $2| tr "," " "))
declare -a openstack_platforms=("centos" "ubuntu")
count=0
## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
    tag=${tvault_version[$count]}
    for openstack_platform in "${openstack_platforms[@]}"
    do
        docker tag trilio/${openstack_platform}-binary-trilio-datamover-api:${tag}-${openstack_release} \
        docker.io/trilio/${openstack_platform}-binary-trilio-datamover-api:${tag}-${openstack_release}
        docker push docker.io/trilio/${openstack_platform}-binary-trilio-datamover-api:${tag}-${openstack_release}

        docker tag trilio/${openstack_platform}-binary-trilio-datamover-api:${tag}-${openstack_release} \
        docker.io/trilio/${openstack_platform}-binary-trilio-datamover-api:${tag}-${openstack_release}
        docker push docker.io/trilio/${openstack_platform}-binary-trilio-datamover:${tag}-${openstack_release}

        docker tag trilio/${openstack_platform}-binary-trilio-horizon-plugin:${tag}-${openstack_release} \
        docker.io/trilio/${openstack_platform}-binary-trilio-horizon-plugin:${tag}-${openstack_release}
        docker push docker.io/trilio/${openstack_platform}-binary-trilio-horizon-plugin:${tag}-${openstack_release}
    done
done
