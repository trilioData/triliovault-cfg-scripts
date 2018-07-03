#!/bin/bash

set -e

if [ $# -ne 2 ]; then
   echo -e "\nError: Script takes exactly two arguments, $# provided\n    First argument: undercloud rc file path \n    Second argument: Roles_data file path which is used to deploy overcloud \n    By default roles data file is present at /usr/share/openstack-tripleo-heat-templates/roles_data.yaml on undercloud \nFor Example:\n    ./prepare_artifacts.sh /home/stack/stackrc /usr/share/openstack-tripleo-heat-templates/roles_data.yaml\n"
   exit 0
fi

undercloud_rc_file=$1
roles_data_file=$2

current_dir=$(pwd)
basedir=$(dirname $0)

if [ $basedir = '.' ]
then
basedir="$current_dir"
fi

cd $basedir/

source $undercloud_rc_file

cp $undercloud_rc_file undercloudrc

chmod +x undercloudrc

##Prepare puppet modules need to upload to obvercloud
rm -rf $basedir/trilio_puppet_modules
mkdir $basedir/trilio_puppet_modules
cp -R ${basedir}/puppet/trilio ${basedir}/trilio_puppet_modules/
cp -R /usr/share/openstack-puppet/modules/tripleo ${basedir}/trilio_puppet_modules/
cp -R ${basedir}/puppet/tripleo/manifests/profile/base/trilio/ ${basedir}/trilio_puppet_modules/tripleo/manifests/profile/base/


##Following command will upload trilio and tripleo puppet modules to overcloud nodes
#As we are adding trilio.pp puppet manifest to trieplo module, we need to upload it to overcloud before deployment
cd ${basedir}/
upload-puppet-modules -d trilio_puppet_modules


##Prepare roles data
/usr/bin/python prepare_roles_data.py $roles_data_file

cd $current_dir
