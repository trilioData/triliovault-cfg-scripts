#!/bin/bash -x

set -e


if [ $# -lt 3 ];then
   echo "Script takes exactly 3 arguments"
   echo -e "./publish_container.sh <tvault_version> <openstack_releases> <containers_to_build>"
   exit 1
fi

tvault_version=($(echo $1| tr "," " "))

declare -a openstack_releases=($(echo $2| tr "," " "))
declare -a containers_to_build=($(echo $3))
declare -a openstack_platforms=("centos" "ubuntu")
#horizon_cont_type required only for Yoga Horizon. Against Yoga, datamover and DMAPI are only source type, hence separate bifurcation not required
declare -a horizon_cont_type=("source" "binary")
count=0
function tagAndPushCont()
{
	docker tag ${1} docker.io/${1}
	docker push docker.io/${1}
}

## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
    tag=${tvault_version[$count]}
    for openstack_platform in "${openstack_platforms[@]}"
    do
        for container_to_build in "${containers_to_build[@]}"
        do
	    #Reset CONT_TAG
	    CONT_TAG=""
	    if [[ ${container_to_build} == *"horizon"* ]]
	    then
      		if [ $(echo "$openstack_release"  | tr '[:upper:]' '[:lower:]') == "yoga" ]
    		then
		    for contType in "${horizon_cont_type[@]}"
		    do
			if [[ ${contType} == *"binary"* ]]
			then
			    #Binary Repos : centos-binary-trilio-horizon-plugin ubuntu-binary-trilio-horizon-plugin
			    CONT_TAG="trilio/${openstack_platform}-binary-${container_to_build}:${tag}-${openstack_release}"
			else
			    #Source Repos : kolla-centos-trilio-horizon-plugin kolla-ubuntu-trilio-horizon-plugin
			    CONT_TAG="trilio/kolla-${openstack_platform}-${container_to_build}:${tag}-${openstack_release}"
			fi
			tagAndPushCont "${CONT_TAG}"
		    done
		else
		    CONT_TAG="trilio/${openstack_platform}-binary-${container_to_build}:${tag}-${openstack_release}"
		    tagAndPushCont "${CONT_TAG}"
		fi
	    else
	        CONT_TAG="trilio/kolla-${openstack_platform}-${container_to_build}:${tag}-${openstack_release}"
		tagAndPushCont "${CONT_TAG}"
	    fi
	done
    done
    let count=count+1
done
