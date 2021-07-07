#!/bin/bash -x

set -e

if [ $# -lt 1 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./install_puppet_module.sh <overcloud_full_image_path>"
   echo -e "Example"
   echo -e "./install_puppet_module.sh /home/stack/images/overcloud-full.qcow2"
   exit 1
fi

overcloud_full_image_path=$1
tmp_working_dir="/tmp/triliovault"
overcloud_full_image_name=`basename $overcloud_full_image_path`


rm -rf $tmp_working_dir
mkdir -p $tmp_working_dir
cp $overcloud_full_image_path ${tmp_working_dir}/
cp trilio.repo ${tmp_working_dir}/

cd ${tmp_working_dir}/
virt-customize --selinux-relabel -a ${overcloud_full_image_name} --upload trilio.repo:/etc/yum.repos.d/
virt-customize --selinux-relabel -a ${overcloud_full_image_name} --install puppet-triliovault
virt-customize --selinux-relabel -a ${overcloud_full_image_name} --run-command  'ln -s /usr/share/openstack-puppet/modules/trilio /etc/puppet/modules/trilio && rm -f /etc/yum.repos.d/trilio.repo'


echo -e "Updated overcloud full image path is: ${tmp_working_dir}/${overcloud_full_image_name}"
echo -e "TrilioVault puppet module is installed in the overcloud image"
echo -e "You need to copy(overwrite) this image to your overcloud images location. Default location is /home/stack/images"
echo -e "Then you need to upload updated images to undercloud glance using following command"
echo -e "openstack overcloud image upload --image-path /home/stack/images/"

## To verify the changes, use following steps
# mkdir /tmp/mnt
# guestmount -a /home/stack/test/overcloud-full.qcow2 -m /dev/sda /tmp/mnt