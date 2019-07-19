#!/bin/bash

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=$1

docker push trilio/centos-source-trilio-datamover-api:${tvault_version}-pike
#docker push trilio/ubuntu-source-trilio-datamover-api:${tvault_version}-pike
docker push trilio/centos-source-trilio-datamover-api:${tvault_version}-queens
docker push trilio/ubuntu-source-trilio-datamover-api:${tvault_version}-queens
docker push trilio/centos-source-trilio-datamover-api:${tvault_version}-rocky
docker push trilio/ubuntu-source-trilio-datamover-api:${tvault_version}-rocky
docker push trilio/centos-source-trilio-datamover-api:${tvault_version}-stein
docker push trilio/ubuntu-source-trilio-datamover-api:${tvault_version}-stein

docker push trilio/centos-source-trilio-datamover:${tvault_version}-pike
#docker push trilio/ubuntu-source-trilio-datamover:${tvault_version}-pike
docker push trilio/centos-source-trilio-datamover:${tvault_version}-queens
docker push trilio/ubuntu-source-trilio-datamover:${tvault_version}-queens
docker push trilio/centos-source-trilio-datamover:${tvault_version}-rocky
docker push trilio/ubuntu-source-trilio-datamover:${tvault_version}-rocky
docker push trilio/centos-source-trilio-datamover:${tvault_version}-stein
docker push trilio/ubuntu-source-trilio-datamover:${tvault_version}-stein
