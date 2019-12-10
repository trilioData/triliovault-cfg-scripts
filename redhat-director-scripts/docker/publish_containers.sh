#!/bin/bash

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=$1


docker tag trilio/trilio-datamover-api:${tvault_version}-rhosp13 docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp13
docker tag trilio/trilio-datamover:${tvault_version}-rhosp13 \
docker.io/trilio/trilio-datamover:${tvault_version}-rhosp13
docker tag trilio/trilio-horizon-plugin:${tvault_version}-rhosp13 docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp13

docker push docker.io/trilio/trilio-datamover-api:${tvault_version}-rhosp13
docker push docker.io/trilio/trilio-datamover:${tvault_version}-rhosp13
docker push docker.io/trilio/trilio-horizon-plugin:${tvault_version}-rhosp13
