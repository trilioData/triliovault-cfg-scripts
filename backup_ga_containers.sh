#!/bin/bash -x

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <GA_release_tvault_version>"
   exit 1
fi

tvault_version=$1

rhosp13_release_tag="${tvault_version}-rhosp13-copy"
rhosp13_qa_tag="${tvault_version}-rhosp13"
rhosp14_release_tag="${tvault_version}-rhosp14-copy"
rhosp14_qa_tag="${tvault_version}-rhosp14"
tripleorocky_release_tag="${tvault_version}-rocky-copy"
tripleorocky_qa_tag="${tvault_version}-rocky"
rhosp15_release_tag="${tvault_version}-rhosp15-copy"
rhosp15_qa_tag="${tvault_version}-rhosp15"



# Publish rhosp13 qa containers
docker pull docker.io/trilio/trilio-datamover:${rhosp13_qa_tag}
docker pull docker.io/trilio/trilio-datamover-api:${rhosp13_qa_tag}
docker pull docker.io/trilio/trilio-horizon-plugin:${rhosp13_qa_tag}

docker tag docker.io/trilio/trilio-datamover:${rhosp13_qa_tag} docker.io/trilio/trilio-datamover:${rhosp13_release_tag}
docker tag docker.io/trilio/trilio-datamover-api:${rhosp13_qa_tag} docker.io/trilio/trilio-datamover-api:${rhosp13_release_tag}
docker tag docker.io/trilio/trilio-horizon-plugin:${rhosp13_qa_tag} docker.io/trilio/trilio-horizon-plugin:${rhosp13_release_tag}


docker push docker.io/trilio/trilio-datamover:${rhosp13_release_tag}
docker push docker.io/trilio/trilio-datamover-api:${rhosp13_release_tag}
docker push docker.io/trilio/trilio-horizon-plugin:${rhosp13_release_tag}

# Publish rhosp14 qa containers
docker pull docker.io/trilio/trilio-datamover:${rhosp14_qa_tag}
docker pull docker.io/trilio/trilio-datamover-api:${rhosp14_qa_tag}
docker pull docker.io/trilio/trilio-horizon-plugin:${rhosp14_qa_tag}

docker tag docker.io/trilio/trilio-datamover:${rhosp14_qa_tag} docker.io/trilio/trilio-datamover:${rhosp14_release_tag}
docker tag docker.io/trilio/trilio-datamover-api:${rhosp14_qa_tag} docker.io/trilio/trilio-datamover-api:${rhosp14_release_tag}
docker tag docker.io/trilio/trilio-horizon-plugin:${rhosp14_qa_tag} docker.io/trilio/trilio-horizon-plugin:${rhosp14_release_tag}

docker push docker.io/trilio/trilio-datamover:${rhosp14_release_tag}
docker push docker.io/trilio/trilio-datamover-api:${rhosp14_release_tag}
docker push docker.io/trilio/trilio-horizon-plugin:${rhosp14_release_tag}



# Publish tripleo rocky qa containers
docker pull docker.io/trilio/trilio-datamover-tripleo:${tripleorocky_qa_tag}
docker pull docker.io/trilio/trilio-datamover-api-tripleo:${tripleorocky_qa_tag}
docker pull docker.io/trilio/trilio-horizon-plugin-tripleo:${tripleorocky_qa_tag}



docker tag docker.io/trilio/trilio-datamover-tripleo:${tripleorocky_qa_tag} docker.io/trilio/trilio-datamover-tripleo:${tripleorocky_release_tag}
docker tag docker.io/trilio/trilio-datamover-api-tripleo:${tripleorocky_qa_tag} docker.io/trilio/trilio-datamover-api-tripleo:${tripleorocky_release_tag}
docker tag docker.io/trilio/trilio-horizon-plugin-tripleo:${tripleorocky_qa_tag} docker.io/trilio/trilio-horizon-plugin-tripleo:${tripleorocky_release_tag}


docker push docker.io/trilio/trilio-datamover-tripleo:${tripleorocky_release_tag}
docker push docker.io/trilio/trilio-datamover-api-tripleo:${tripleorocky_release_tag}
docker push docker.io/trilio/trilio-horizon-plugin-tripleo:${tripleorocky_release_tag}




# Publish rhosp15 qa containers
podman pull docker.io/trilio/trilio-datamover:${rhosp15_qa_tag}
podman pull docker.io/trilio/trilio-datamover-api:${rhosp15_qa_tag}
podman pull docker.io/trilio/trilio-horizon-plugin:${rhosp15_qa_tag}


podman tag docker.io/trilio/trilio-datamover:${rhosp15_qa_tag} docker.io/trilio/trilio-datamover:${rhosp15_release_tag}
podman tag docker.io/trilio/trilio-datamover-api:${rhosp15_qa_tag} docker.io/trilio/trilio-datamover-api:${rhosp15_release_tag}
podman tag docker.io/trilio/trilio-horizon-plugin:${rhosp15_qa_tag} docker.io/trilio/trilio-horizon-plugin:${rhosp15_release_tag}

podman push docker.io/trilio/trilio-datamover:${rhosp15_release_tag}
podman push docker.io/trilio/trilio-datamover-api:${rhosp15_release_tag}
podman push docker.io/trilio/trilio-horizon-plugin:${rhosp15_release_tag}


# Publish kolla ansible release containers
declare -a openstack_releases=("queens" "rocky" "stein")

declare -a openstack_platforms=("centos" "ubuntu")


## now loop through the above array

for openstack_release in "${openstack_releases[@]}"
do
    for openstack_platform in "${openstack_platforms[@]}"
    do
	
        docker pull trilio/${openstack_platform}-source-trilio-datamover:${tvault_version}-${openstack_release}
	docker pull trilio/${openstack_platform}-source-trilio-datamover-api:${tvault_version}-${openstack_release}
								
				
	docker tag trilio/${openstack_platform}-source-trilio-datamover:${tvault_version}-${openstack_release} trilio/${openstack_platform}-source-trilio-datamover:${tvault_version}-${openstack_release}-copy
	docker tag trilio/${openstack_platform}-source-trilio-datamover-api:${tvault_version}-${openstack_release} trilio/${openstack_platform}-source-trilio-datamover-api:${tvault_version}-${openstack_release}-copy
								
	docker push trilio/${openstack_platform}-source-trilio-datamover:${tvault_version}-${openstack_release}-copy
        docker push trilio/${openstack_platform}-source-trilio-datamover-api:${tvault_version}-${openstack_release}-copy

    done
done
