#!/bin/bash -x

set -e


if [ $# -lt 1 ];then
   echo "Script takes exactly 1 arguments"
   echo -e "./deploy_trilio_on_kolla_ansible.sh <trilio_container_tag>"
   exit 1
fi


tag=$1

##Select backup target nfs/s3 for tvault backups
BACKUP_TARGET='nfs'

#Python executable path inside container
PYTHON_PATH=/var/lib/kolla/venv/bin/python
DATAMOVER_CONFIG_DIR="/etc/kolla/trilio-datamover"
DATAMOVER_API_CONFIG_DIR="/etc/kolla/trilio-datamover-api"

DATAMOVER_LOG_DIR="/var/log/kolla/trilio-datamover"
DATAMOVER_API_LOG_DIR="/var/log/kolla/trilio-datamover-api"



echo -e "Trilio container tag provided:$tag"

##Pull docker containers from dockerhub
docker pull shyambiradar/ubuntu-source-trilio-datamover:$tag
docker pull shyambiradar/ubuntu-source-trilio-datamover-api:$tag



##Prepare config directories ##Please perform these steps manually on production enviornment
##These steps are only need if it's single node kolla-ansible deployed openstack cloud

##Perform on all nodes where nova_compute service is deployed
mkdir -p $DATAMOVER_CONFIG_DIR
mkdir -p $DATAMOVER_LOG_DIR
chown nova:nova $DATAMOVER_LOG_DIR

##Perform on all nodes where nova_api service is deployed
mkdir -p $DATAMOVER_API_CONFIG_DIR
mkdir -p $DATAMOVER_API_LOG_DIR
chown nova:nova $DATAMOVER_API_LOG_DIR


#### Run Datamover container
###Uncomment following command If ceph is backend storage for nova or cinder

#docker run --network host --name trilio_datamover -d \
#-v $DATAMOVER_CONFIG_DIR/tvault-contego.conf:/etc/tvault-contego/tvault-contego.conf \
#-v $DATAMOVER_CONFIG_DIR/nova.conf:/etc/nova/nova.conf \
#-v $DATAMOVER_CONFIG_DIR/ceph.conf:/etc/ceph/ceph.conf \
#-v $DATAMOVER_CONFIG_DIR/ceph.client.nova.keyring:/etc/ceph/ceph.client.nova.keyring \
#-v /dev:/dev:rw \
#-v nova_compute:/var/lib/nova/:rw \
#-v /var/log/kolla/:/var/log/kolla/ \
#-v iscsi_info:/etc/iscsi:rw -v /var/run/libvirt \
#shyambiradar/ubuntu-source-trilio-datamover:$tag /opt/tvault/start_datamover_nfs

#If ceph storage is not used for nova, cinder
docker run --privileged --network host --name trilio_datamover -it \
-v $DATAMOVER_CONFIG_DIR/tvault-contego.conf:/etc/tvault-contego/tvault-contego.conf \
-v $DATAMOVER_CONFIG_DIR/nova.conf:/etc/nova/nova.conf \
-v /dev:/dev:rw \
-v nova_compute:/var/lib/nova/:rw \
-v /var/log/kolla/:/var/log/kolla/ \
-v iscsi_info:/etc/iscsi:rw -v /var/run/libvirt \
shyambiradar/ubuntu-source-trilio-datamover:$tag /opt/tvault/start_datamover_nfs


#### Run Datamover Api container
docker run --network host --name trilio_datamover_api -d -v $DATAMOVER_API_CONFIG_DIR/nova.conf:/etc/nova/nova.conf \
-v $DATAMOVER_API_CONFIG_DIR/dmapi.conf:/etc/dmapi/dmapi.conf \
-v /var/log/kolla/:/var/log/kolla/ \
shyambiradar/ubuntu-source-trilio-datamover-api:$tag $PYTHON_PATH /usr/bin/dmapi-api
