#!/bin/bash

set -e

if [ $# -ne 2 ]; then
   echo -e "\nError: Script takes exactly three arguments, $# provided\n    First argument:    undercloud rc file path \n    Second argument:    TrilioVault VM/cluster IP \nFor Example:\n    ./prepare_artifacts.sh /home/stack/stackrc 192.168.122.201\n"
   exit 0
fi

undercloud_rc_file=$1
tvault_ip=$2


current_dir=$(pwd)
basedir=$(dirname $0)

if [ $basedir = '.' ]
then
basedir="$current_dir"
fi

cd ${basedir}/
rm -f ${basedir}/*.rpm
source $undercloud_rc_file
cp $undercloud_rc_file undercloudrc
chmod +x undercloudrc


tvault_version=`curl -s http://${tvault_ip}:8081/packages/ | grep tvault-contego-[0-9] | awk -F 'tvault-contego-' '{print $2}' | awk -F 'tar.gz' '{print $1}' | sed 's/.\{1\}$//'`

tvault_release=`echo $tvault_version | awk '{split($0,a,"."); print a[1], a[2]}'`
tvault_release=`echo $tvault_release | sed 's/\ /\./'`

sudo rm -f etc/yum.repos.d/trilio.repo
sudo rm -f triliorepo.tgz
sudo mkdir -p ${basedir}/etc/yum.repos.d/
sudo cp ${basedir}/trilio.repo.template ${basedir}/etc/yum.repos.d/trilio.repo
sudo sed -i "s/TVAULTIP/${tvault_ip}/" ${basedir}/etc/yum.repos.d/trilio.repo
sudo chmod 755 ${basedir}/etc
sudo chmod 755 ${basedir}/etc/yum.repos.d
sudo chmod 644 ${basedir}/etc/yum.repos.d/trilio.repo
sudo chown -R root:root ${basedir}/etc
/usr/bin/tar -cvzf triliorepo.tgz etc
/usr/bin/upload-swift-artifacts -f triliorepo.tgz --environment ${basedir}/trilio_artifacts.yaml


sudo rm -rf trilio-puppet-module
sudo mkdir trilio-puppet-module
sudo cp -R puppet/trilio trilio-puppet-module/
sudo chmod 777 trilio-puppet-module/trilio
sudo chown -R root:root trilio-puppet-module/
upload-puppet-modules -d trilio-puppet-module


##Merge both templates in one file
tail -1 ${basedir}/trilio_artifacts.yaml >> ~/.tripleo/environments/puppet-modules-url.yaml
rm -f ${basedir}/trilio_artifacts.yaml
