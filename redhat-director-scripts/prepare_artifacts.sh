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

rpm1="puppet-triliovault-${tvault_version}-${tvault_release}.noarch.rpm"

curl -O http://${tvault_ip}:8085/yum-repo/${rpm1}

if [ ! -f $rpm1 ]; then
    echo "rpm download failed, rpm name: $rpm1"
    exit 1
fi

rm -rf etc/
rm -f triliorepo.tgz
mkdir -p ${basedir}/etc/yum.repos.d/
cp ${basedir}/trilio.repo.template ${basedir}/etc/yum.repos.d/trilio.repo
sed -i "s/TVAULTIP/${tvault_ip}/" ${basedir}/etc/yum.repos.d/trilio.repo
/usr/bin/tar -cvzf triliorepo.tgz etc
/usr/bin/upload-swift-artifacts -f triliorepo.tgz -f $rpm1 --environment ${basedir}/trilio_artifacts.yaml


rm -rf trilio-puppet-module
mkdir trilio-puppet-module
cp -R puppet/trilio trilio-puppet-module/
upload-puppet-modules -d trilio-puppet-module


##Merge both templates in one file
tail -1 ${basedir}/trilio_artifacts.yaml >> ~/.tripleo/environments/puppet-modules-url.yaml
rm -f ${basedir}/trilio_artifacts.yaml
