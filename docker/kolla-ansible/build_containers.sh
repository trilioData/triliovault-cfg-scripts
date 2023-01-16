#!/bin/bash -x

set -e

if [ $# -lt 4 ];then
   echo "Script takes exactly 4 arguments"
   echo -e "./build_container.sh <tvault_version> <openstack_releases> <fury_organization> <containers_to_build>"
   exit 1
fi

tvault_version=($(echo $1| tr "," " "))

current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi

declare -a openstack_releases=($(echo $2| tr "," " "))
fury_repo=$(echo $3)
declare -a containers_to_build=($(echo $4))

declare -a openstack_platforms=("centos" "ubuntu")
#horizon_cont_type required only for Yoga Horizon. Against Yoga, datamover and DMAPI are only source type, hence separate bifurcation not required
declare -a horizon_cont_type=("source" "binary")
count=0
## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
	tag=${tvault_version[$count]}

    for openstack_platform in "${openstack_platforms[@]}"
    do
	build_dir=tmp_docker_${openstack_release}_${openstack_platform}
        rm -rf $base_dir/${build_dir}
       	mkdir -p $base_dir/${build_dir}

        for container_to_build in "${containers_to_build[@]}"
        do
                cp -R $base_dir/${container_to_build} $base_dir/${build_dir}/
		#Build containers
		echo -e "Creating ${container_to_build} container for kolla ${openstack_release} ${openstack_platform}"
		cd $base_dir/${build_dir}/${container_to_build}/
		sed -i "s/{VERSION}/${fury_repo}/g" trilio.repo
		sed -i "s/{VERSION}/${fury_repo}/g" trilio.list

		if [[ ${container_to_build} == *"horizon"* ]]
		then
      		    if [ $(echo "$openstack_release"  | tr '[:upper:]' '[:lower:]') == "yoga" ]
    		    then
		        #Dockerfile_yoga_centos_binary Dockerfile_yoga_centos_source Dockerfile_yoga_ubuntu_binary Dockerfile_yoga_ubuntu_source
			for contType in "${horizon_cont_type[@]}"
			do
			    mv Dockerfile_${openstack_release}_${openstack_platform}_${contType} Dockerfile
			    if [[ ${contType} == *"binary"* ]]
			    then
			        #Binary Repos : centos-binary-trilio-horizon-plugin ubuntu-binary-trilio-horizon-plugin
				docker build --no-cache --pull -t trilio/${openstack_platform}-binary-${container_to_build}:${tag}-${openstack_release} .
			    else
			        #Source Repos : kolla-centos-trilio-horizon-plugin kolla-ubuntu-trilio-horizon-plugin
				docker build --no-cache --pull -t trilio/kolla-${openstack_platform}-${container_to_build}:${tag}-${openstack_release} .
			    fi
			done
		    else
		        mv Dockerfile_${openstack_release}_${openstack_platform} Dockerfile
		        docker build --no-cache --pull -t trilio/${openstack_platform}-binary-${container_to_build}:${tag}-${openstack_release} .
		    fi
		else
		    #Docker hub repo/tag for all non horizon containers to be in format <distro>-<os platform>-<container>. 
		    #Eg. kolla-centos-trilio-dataover
		    mv Dockerfile_${openstack_release}_${openstack_platform} Dockerfile
		    docker build --no-cache --pull -t trilio/kolla-${openstack_platform}-${container_to_build}:${tag}-${openstack_release} .
		fi
        done
    	# Clean the build_dir
	rm -rf $base_dir/${build_dir}
    done
    let count=count+1
done
