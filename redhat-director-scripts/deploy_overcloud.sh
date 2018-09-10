#!/bin/bash -x

set -e 


current_dir=$(pwd)
basedir=$(dirname $0)

if [ $basedir = '.' ]
then
basedir="$current_dir"
fi


source /home/stack/stackrc

##Overcloud deployment command with trilio components
#It will install trilio datamover daemon on all compute nodes
#It will install trilio datamover api part on all controller nodes
#It will install trilio horizon plugin on all controller nodes

openstack overcloud deploy --templates \
--environment-directory /home/stack/templates \
-e ${basedir}/trilio_env.yaml \
-r ${basedir}/roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org \
