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
source $undercloud_rc_file
cp $undercloud_rc_file undercloudrc
chmod +x undercloudrc


tvault_version=`curl -s http://${tvault_ip}:8081/packages/ | grep tvault-contego-[0-9] | awk -F 'tvault-contego-' '{print $2}' | awk -F 'tar.gz' '{print $1}' | sed 's/.\{1\}$//'`

tvault_release=`echo $tvault_version | awk '{split($0,a,"."); print a[1], a[2]}'`
tvault_release=`echo $tvault_release | sed 's/\ /\./'`

rpm1="puppet-triliovault-${tvault_version}-${tvault_release}.noarch.rpm"
rpm2="tvault-contego-${tvault_version}-${tvault_release}.noarch.rpm"
rpm3="tvault-contego-api-${tvault_version}-${tvault_release}.noarch.rpm"
rpm4="tvault-horizon-plugin-${tvault_version}-${tvault_release}.noarch.rpm"
rpm5="python-workloadmgrclient-${tvault_version}-${tvault_release}.noarch.rpm"

curl -O http://${tvault_ip}:8085/yum-repo/${rpm1}
curl -O http://${tvault_ip}:8085/yum-repo/${rpm2}
curl -O http://${tvault_ip}:8085/yum-repo/${rpm3}
curl -O http://${tvault_ip}:8085/yum-repo/${rpm4}
curl -O http://${tvault_ip}:8085/yum-repo/${rpm5}

if [ ! -f $rpm_name ]; then
    echo "rpm download failed, rpm name: $rpm_name"
    exit 1
fi

rm -rf etc/
rm -f triliorepo.tgz
mkdir -p ${basedir}/etc/yum.repos.d/
cp ${basedir}/trilio.repo.template ${basedir}/etc/yum.repos.d/trilio.repo
sed -i.bak "s/TVAULTIP/${tvault_ip}/" ${basedir}/etc/yum.repos.d/trilio.repo
/usr/bin/tar -cvzf triliorepo.tgz etc
/usr/bin/upload-swift-artifacts -f triliorepo.tgz -f $rpm1 -f $rpm2 -f $rpm3 -f $rpm4 -f $rpm5 --environment ${basedir}/trilio_artifacts.yaml
