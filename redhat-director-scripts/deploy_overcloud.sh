#!/bin/bash -x

set -e 


current_dir=$(pwd)
basedir=$(dirname $0)

if [ $basedir = '.' ]
then
basedir="$current_dir"
fi


source ${basedir}/undercloudrc

##Overcloud deployment command with trilio components
#It will install trilio datamover daemon on all compute nodes
#It will install trilio datamover api part on all controller nodes
#It will install trilio horizon plugin on all controller nodes

openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /home/stack/templates/network-environment.yaml \
-e /home/stack/templates/storage-environment.yaml \
-e ${basedir}/trilio_env.yaml \
-r ${basedir}/roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log
