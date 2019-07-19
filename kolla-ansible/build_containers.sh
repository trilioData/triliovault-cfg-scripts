#!/bin/bash

set -e


if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./build_container.sh <tvault_version>"
   exit 1
fi

tvault_version=$1



current_dir=$(pwd)
base_dir=$(dirname $0)

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi


## Create Pike containers
echo -e "Creating trilio-datamover container for pike centos"
cd $base_dir/pike/centos/docker/trilio-datamover/
docker build --no-cache -t kolla/centos-source-trilio-datamover:${tvault_version}-pike .
cd $base_dir/pike/centos/docker/trilio-datamover-api/
docker build --no-cache -t kolla/centos-source-trilio-datamover-api:${tvault_version}-pike .

echo -e "Creating trilio-datamover container for pike ubuntu"
cd $base_dir/pike/ubuntu/docker/trilio-datamover/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover:${tvault_version}-pike .
cd $base_dir/pike/ubuntu/docker/trilio-datamover-api/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover-api:${tvault_version}-pike .

##Queens
echo -e "Creating trilio-datamover container for queens centos"
cd $base_dir/queens/centos/docker/trilio-datamover/
docker build --no-cache -t kolla/centos-source-trilio-datamover:${tvault_version}-queens .
cd $base_dir/queens/centos/docker/trilio-datamover-api/
docker build --no-cache -t kolla/centos-source-trilio-datamover-api:${tvault_version}-queens .

echo -e "Creating trilio-datamover container for queens ubuntu"
cd $base_dir/queens/ubuntu/docker/trilio-datamover/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover:${tvault_version}-queens .
cd $base_dir/queens/ubuntu/docker/trilio-datamover-api/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover-api:${tvault_version}-queens .


##Rocky
echo -e "Creating trilio-datamover container for rocky centos"
cd $base_dir/rocky/centos/docker/trilio-datamover/
docker build --no-cache -t kolla/centos-source-trilio-datamover:${tvault_version}-rocky .
cd $base_dir/rocky/centos/docker/trilio-datamover-api/
docker build --no-cache -t kolla/centos-source-trilio-datamover-api:${tvault_version}-rocky .

echo -e "Creating trilio-datamover container for rocky ubuntu"
cd $base_dir/rocky/ubuntu/docker/trilio-datamover/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover:${tvault_version}-rocky .
cd $base_dir/rocky/ubuntu/docker/trilio-datamover-api/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover-api:${tvault_version}-rocky .


##Stein
echo -e "Creating trilio-datamover container for stein centos"
cd $base_dir/stein/centos/docker/trilio-datamover/
docker build --no-cache -t kolla/centos-source-trilio-datamover:${tvault_version}-stein .
cd $base_dir/stein/centos/docker/trilio-datamover-api/
docker build --no-cache -t kolla/centos-source-trilio-datamover-api:${tvault_version}-stein .

echo -e "Creating trilio-datamover container for stein ubuntu"
cd $base_dir/stein/ubuntu/docker/trilio-datamover/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover:${tvault_version}-stein .
cd $base_dir/stein/ubuntu/docker/trilio-datamover-api/
docker build --no-cache -t kolla/ubuntu-source-trilio-datamover-api:${tvault_version}-stein .
