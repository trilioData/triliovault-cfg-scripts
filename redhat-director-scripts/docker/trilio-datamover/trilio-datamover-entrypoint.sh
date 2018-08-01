#!/usr/bin/env bash

backup_target_type=$1

if [ "$backup_target_type" == "nfs" ]; then
    nfs_shares=$2
    nfs_options=$3
	sed -i "/vault_storage_type/c\vault_storage_type=nfs" /etc/tvault-contego/tvault-contego.conf
    sed -i "/vault_storage_nfs_export/c\vault_storage_nfs_export=${nfs_shares}" /etc/tvault-contego/tvault-contego.conf
	sed -i "/vault_storage_nfs_options/c\vault_storage_nfs_options=${nfs_options}" /etc/tvault-contego/tvault-contego.conf
elif [ "$backup_target_type" == "amazon_s3" ]; then
    s3_access_key_id=$2
    s3_secret_access_key=$3
    s3_region_name=$4
    s3_bucket=$5
	sed -i "/vault_storage_type/c\vault_storage_type=s3" /etc/tvault-contego/tvault-contego.conf
    sed -i "/vault_s3_access_key_id/c\vault_s3_access_key_id=${s3_access_key_id}" /etc/tvault-contego/tvault-contego.conf
	sed -i "/vault_s3_secret_access_key/c\vault_s3_secret_access_key=${s3_secret_access_key}" /etc/tvault-contego/tvault-contego.conf
    sed -i "/vault_s3_region_name/c\vault_s3_region_name=${s3_region_name}" /etc/tvault-contego/tvault-contego.conf
	sed -i "/vault_s3_bucket/c\vault_s3_bucket=${s3_bucket}" /etc/tvault-contego/tvault-contego.conf		
elif [ "$backup_target_type" == "ceph_s3" ]; then
    s3_access_key_id=$2
    s3_secret_access_key=$3
    s3_region_name="us-east-1"
    s3_endpoint_url=$4
    s3_bucket=$5
    s3_ssl=$6
	sed -i "/vault_storage_type/c\vault_storage_type=s3" /etc/tvault-contego/tvault-contego.conf
    sed -i "/vault_s3_access_key_id/c\vault_s3_access_key_id=${s3_access_key_id}" /etc/tvault-contego/tvault-contego.conf
	sed -i "/vault_s3_secret_access_key/c\vault_s3_secret_access_key=${s3_secret_access_key}" /etc/tvault-contego/tvault-contego.conf
    sed -i "/vault_s3_region_name/c\vault_s3_region_name=us-east-1" /etc/tvault-contego/tvault-contego.conf
	sed -i "/vault_s3_bucket/c\vault_s3_bucket=${s3_bucket}" /etc/tvault-contego/tvault-contego.conf
    sed -i "/vault_s3_endpoint_url/c\vault_s3_endpoint_url=${s3_endpoint_url}" /etc/tvault-contego/tvault-contego.conf
    sed -i "/vault_s3_ssl/c\vault_s3_ssl=${s3_ssl}" /etc/tvault-contego/tvault-contego.conf	
fi

sudo /home/tvault/.virtenv/bin/python /home/tvault/.virtenv/bin/tvault-contego --config-file=/usr/share/nova/nova-dist.conf \
--config-file=/etc/nova/nova.conf --config-file=/etc/tvault-contego/tvault-contego.conf
