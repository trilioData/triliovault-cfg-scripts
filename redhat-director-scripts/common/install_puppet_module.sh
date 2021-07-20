#!/bin/bash -x

set -e

if [ $# -lt 3 ];then
   echo "Script takes exacyly 1 argument"
   echo -e "./install_puppet_module.sh <OVERCLOUD_FULL_IMAGE_PATH> <TRILIO_RPM_REPO_USERNAME> <TRILIO_RPM_REPO_PASSWORD>"
   echo -e "Example: [Get rpm repo username nad password from trilio team]"
   echo -e "./install_puppet_module.sh /home/stack/images/overcloud-full.qcow2 test_user test_password"
   exit 1
fi


overcloud_full_image_path=$1
rpm_repo_user=$2
rpm_repo_password=$3

cat > trilio.repo <<EOF
[triliovault-4-1]
name=triliovault-4-1
baseurl=http://${rpm_repo_user}:${rpm_repo_password}@repos.trilio.io:8283/triliovault-4.1-dev/yum/
gpgcheck=0
enabled=1
EOF


export LIBGUESTFS_BACKEND=direct

virt-customize --selinux-relabel -a ${overcloud_full_image_path} --commands-from-file ./virt_commands

virt-customize --selinux-relabel -a ${overcloud_full_image_path} --run-command  'ln -s /usr/share/openstack-puppet/modules/trilio /etc/puppet/modules/trilio && rm -f /etc/yum.repos.d/trilio.repo'

virt-sysprep --operation machine-id -a ${overcloud_full_image_path}

echo -e "Updated overcloud full image path is: ${overcloud_full_image_path}"
echo -e "TrilioVault puppet module is installed in the overcloud image"
echo -e "You need to upload updated images to undercloud glance using following command"
echo -e "openstack overcloud image upload --image-path --update-existing /home/stack/images/"