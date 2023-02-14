#!/bin/bash

set -e

if [ $# -lt 2 ];then
   echo "Script takes exactly 2 arguments"
   echo -e "./publish_container.sh <tvault_version> <containers_to_build>"
   exit 1
fi

tvault_version=$1

declare -a containers_to_build=($(echo $3))
for container_to_build in "${containers_to_build[@]}"
do
	docker tag trilio/${container_to_build}:${tvault_version}-rhosp13 docker.io/trilio/${container_to_build}:${tvault_version}-rhosp13
	docker push docker.io/trilio/${container_to_build}:${tvault_version}-rhosp13
done
