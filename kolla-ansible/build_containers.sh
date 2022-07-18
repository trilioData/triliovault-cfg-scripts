#!/bin/bash -x

set -e

if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
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

declare -a openstack_platforms=("centos" "ubuntu")
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
		cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
		cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
                cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

                docker pull kolla/${openstack_platform}-binary-nova-compute:${openstack_release}
                docker pull kolla/${openstack_platform}-binary-horizon:${openstack_release}
                docker pull kolla/${openstack_platform}-binary-nova-api:${openstack_release}
 
		#Build trilio-datamover containers
		#echo -e "Creating trilio-datamover container for kolla ${openstack_release} ${openstack_platform}"
		#cd $base_dir/${build_dir}/trilio-datamover/
		#mv Dockerfile_${openstack_release}_${openstack_platform} Dockerfile
		#docker build --no-cache -t trilio/${openstack_platform}-binary-trilio-datamover:${tag}-${openstack_release} .
		echo "Skipping trilio-datamover container for kolla ${openstack_release} ${openstack_platform}"


		#Build trilio_datamover-api containers
		#echo -e "Creating trilio-datamover container-api for kolla ${openstack_release} ${openstack_platform}"
		#cd $base_dir/${build_dir}/trilio-datamover-api/
		#mv Dockerfile_${openstack_release}_${openstack_platform} Dockerfile
		#docker build --no-cache -t trilio/${openstack_platform}-binary-trilio-datamover-api:${tag}-${openstack_release} .
		echo "Skipping trilio-datamover-api container for kolla ${openstack_release} ${openstack_platform}"


		echo -e "Creating trilio-horizon-plugin container for kolla ${openstack_release} ${openstack_platform}"
		cd $base_dir/${build_dir}/trilio-horizon-plugin/
		mv Dockerfile_${openstack_release}_${openstack_platform} Dockerfile
		docker build --no-cache -t trilio/${openstack_platform}-binary-trilio-horizon-plugin:${tag}-${openstack_release} .
    	# Clean the build_dir
		rm -rf $base_dir/${build_dir}

    done
	let count=count+1
done
