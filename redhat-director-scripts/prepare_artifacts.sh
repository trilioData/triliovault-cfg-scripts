#!/bin/bash -x

set -e

if [ $# -ne 1 ]; then
   echo -e "Provide roles_data file path as argument to this script \nBy default it present at /usr/share/openstack-tripleo-heat-templates/roles_data.yaml on undercloud \nLike this:\n./prepare_artifacts.sh /usr/share/openstack-tripleo-heat-templates/roles_data.yaml"
   exit 0
fi


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
cp -R /usr/share/openstack-puppet/modules/tripleo ${basedir}/trilio_puppet_modules/
cp -R ${basedir}/puppet/tripleo/manifests/profile/base/trilio/ ${basedir}/trilio_puppet_modules/tripleo/manifests/profile/base/


##Following command will upload trilio and tripleo puppet modules to overcloud nodes
#As we are adding trilio.pp puppet manifest to trieplo module, we need to upload it to overcloud before deployment
cd ${basedir}/
upload-puppet-modules -d trilio_puppet_modules


##Prepare roles data
/usr/bin/python prepare_roles_data.py $1
