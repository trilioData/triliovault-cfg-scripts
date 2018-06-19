#!/bin/bash -x

set -e 

current_dir=$(pwd)
basedir=$(dirname $0)
echo "$BASEDIR" 
echo "$current_dir"

if [ $basedir = '.' ]
then
basedir="$current_dir"
fi


##Prepare puppet modules need to upload to obvercloud
rm -rf $basedir/trilio_puppet_modules
mkdir $basedir/trilio_puppet_modules
cp -R ${basedir}/puppet/trilio ${basedir}/trilio_puppet_modules/
cp -R /etc/puppet/modules/tripleo ${basedir}/trilio_puppet_modules/
cp -R ${basedir}/puppet/tripleo/manifests/profile/base/trilio/ ${basedir}/trilio_puppet_modules/tripleo/manifests/profile/base/


##Following command will upload trilio and tripleo puppet modules to overcloud nodes
#As we are adding trilio.pp puppet manifest to trieplo module, we need to upload it to overcloud before deployment
#upload-puppet-modules -d trilio_puppet_modules



##Overcloud deployment command with trilio components
#It will install trilio datamover daemon on all compute nodes
#It will install trilio datamover api part on all controller nodes
#It will install trilio horizon plugin on all controller nodes

#openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
#-e /home/stack/templates/network-environment.yaml \
#-e /home/stack/templates/storage-environment.yaml \
#-e /home/stack/templates/tripleo-integration/trilio_env.yaml \
#-r /home/stack/templates/tripleo-integration/trilio_roles_data.yaml \
#--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
#--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
#--validation-errors-fatal --validation-warnings-fatal \
#--log-file overcloud_deploy.log
