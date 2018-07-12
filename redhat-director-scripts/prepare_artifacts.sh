#!/bin/bash -x

set -e

if [ $# -ne 3 ]; then
   echo -e "\nError: Script takes exactly three arguments, $# provided\n    First argument:    undercloud rc file path \n    Second argument:   Roles_data file path which is used to deploy overcloud \n    Third argument:    TrilioVault VM/cluster IP \n    By default roles data file is present at /usr/share/openstack-tripleo-heat-templates/roles_data.yaml on undercloud\nFor Example:\n    ./prepare_artifacts.sh /home/stack/stackrc /usr/share/openstack-tripleo-heat-templates/roles_data.yaml 192.168.122.201\n"
   exit 0
fi

undercloud_rc_file=$1
roles_data_file=$2
tvault_ip=$3


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


tvault_version=`curl -s http://${tvault_ip}:8081/packages/ | grep tvault-contego-[0-9] | awk -F 'tvault-contego-' '{print $2}' | awk -F 'tar.gz' '{print $1}' | sed 's/.\{1\}$//'`

tvault_release=`echo $tvault_version | awk '{split($0,a,"."); print a[1], a[2]}'`
tvault_release=`echo $tvault_release | sed 's/\ /\./'`
rpm_name="puppet-triliovault-${tvault_version}-${tvault_release}.noarch.rpm"

curl -O http://${tvault_ip}:8085/yum-repo/${rpm_name}
if [ ! -f $rpm_name ]; then
    echo "rpm download failed, rpm name: $rpm_name"
    exit 1
fi


mkdir -p etc/yum.repos.d/
sed -i.bak "s/TVAULTIP/${tvault_ip}/" $basedir/trilio.repo
cp $basedir/trilio.repo ${basedir}/etc/yum.repos.d/
tar -cvzf triliorepo.tgz etc

upload-swift-artifacts -f triliorepo.tgz -f $rpm_name

##Prepare roles data
/usr/bin/python prepare_roles_data.py $roles_data_file

cd $current_dir
