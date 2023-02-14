#!/bin/bash -x

set -e

if [ $# -lt 2 ];then
   echo "Script takes exactly 2 arguments"
   echo -e "./build_tripleo_containers.sh <tvault_version> <containers_to_build>"
   exit 1
fi

tvault_version=$1


current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi


openstack_distro="tripleo"

declare -a openstack_releases=("train")
#Commenting for 4.2.HF2 only
#declare -a openstack_releases=("train" "wallaby")

declare -a openstack_platforms=("centos7")
#Commenting for 4.2.HF2 only
#declare -a openstack_platforms=("centos7" "centos8s")
declare -a containers_to_build=($(echo $2))

declare -a base_containers=("docker.io/tripleotrain/centos-binary-nova-compute:current-tripleo-rdo" "docker.io/tripleotrain/centos-binary-nova-api:current-tripleo-rdo" "docker.io/tripleotrain/centos-binary-horizon:current-tripleo-rdo")

#Commenting for 4.2.HF2 only
#declare -a base_containers=("docker.io/tripleotrain/centos-binary-nova-compute:current-tripleo-rdo" "docker.io/tripleotrain/centos-binary-nova-api:current-tripleo-rdo" "docker.io/tripleotrain/centos-binary-horizon:current-tripleo-rdo" "docker.io/tripleotraincentos8/centos-binary-nova-compute:current-tripleo-rdo" "docker.io/tripleotraincentos8/centos-binary-nova-api:current-tripleo-rdo" "docker.io/tripleotraincentos8/centos-binary-horizon:current-tripleo-rdo" "docker.io/tripleowallaby/openstack-nova-compute:current-tripleo-rdo" "docker.io/tripleowallaby/openstack-nova-api:current-tripleo-rdo" "docker.io/tripleowallaby/openstack-horizon:current-tripleo-rdo")


for base_container in "${base_containers[@]}"
do
        podman pull ${base_container}
done
## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
    for openstack_platform in "${openstack_platforms[@]}"
    do
	build_dir=tmp_docker_${openstack_distro}_${openstack_release}_${openstack_platform}
        rm -rf $base_dir/${build_dir}
        mkdir -p $base_dir/${build_dir}
	cp -R $base_dir/trilio-datamover $base_dir/${build_dir}/
	cp -R $base_dir/trilio-datamover-api $base_dir/${build_dir}/
        cp -R $base_dir/trilio-horizon-plugin $base_dir/${build_dir}/

	#Build trilio-datamover containers
	echo -e "Creating trilio-datamover container for tripleo ${openstack_releases[$count]} ${openstack_platforms[$count]}"
	cd $base_dir/${build_dir}/trilio-datamover/
	mv Dockerfile_${openstack_distro}_${openstack_releases[$count]}_${openstack_platforms[$count]} Dockerfile
	curl https://trunk.rdoproject.org/centos8/component/tripleo/current/delorean.repo > delorean-component-tripleo.repo
	curl -O http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-8-4.el8.noarch.rpm
	curl -O http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-stream-repos-8-4.el8.noarch.rpm
	buildah bud --format docker -t trilio/${openstack_distro}-${openstack_releases[$count]}-${openstack_platforms[$count]}-trilio-datamover:${tvault_version}-${openstack_distro} .


	#Build trilio_datamover-api containers
	echo -e "Creating trilio-datamover container-api for tripleo ${openstack_releases[$count]} ${openstack_platforms[$count]}"
	cd $base_dir/${build_dir}/trilio-datamover-api/
	mv Dockerfile_${openstack_distro}_${openstack_releases[$count]}_${openstack_platforms[$count]} Dockerfile
	curl -O http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-8-4.el8.noarch.rpm
	curl -O http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-stream-repos-8-4.el8.noarch.rpm
	curl https://trunk.rdoproject.org/centos8/component/tripleo/current/delorean.repo > delorean-component-tripleo.repo
	buildah bud --format docker -t trilio/${openstack_distro}-${openstack_releases[$count]}-${openstack_platforms[$count]}-trilio-datamover-api:${tvault_version}-${openstack_distro} .


	#Build trilio_horizon_plugin containers
	echo -e "Creating trilio-horizon-plugin container for tripleo ${openstack_releases[$count]} ${openstack_platforms[$count]}"
	cd $base_dir/${build_dir}/trilio-horizon-plugin/
	mv Dockerfile_${openstack_distro}_${openstack_releases[$count]}_${openstack_platforms[$count]} Dockerfile
	curl -O http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-8-4.el8.noarch.rpm
	curl -O http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-stream-repos-8-4.el8.noarch.rpm
	curl https://trunk.rdoproject.org/centos8/component/tripleo/current/delorean.repo > delorean-component-tripleo.repo
	buildah bud --format docker -t trilio/${openstack_distro}-${openstack_releases[$count]}-${openstack_platforms[$count]}-trilio-horizon-plugin:${tvault_version}-${openstack_distro} .

	# Clean the build_dir
	rm -rf $base_dir/${build_dir}
        let count=count+1
done
