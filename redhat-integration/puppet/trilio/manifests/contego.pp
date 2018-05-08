class trilio::contego (
    $redhat_openstack_version             = '10',
    $tvault_appliance_ip                  = undef,
    $nova_conf_file			  = '/etc/nova/nova.conf',
    $nova_dist_conf_file		  = '/usr/share/nova/nova-dist.conf',
    $backup_target_type                   = 'nfs',   ##Other values: swift, s3
    $nfs_shares				  = undef,
    $nfs_options			  = 'nolock,soft,timeo=180,intr',
    $swift_auth_version                   = 'tempauth',          ## Other values: keystone_v2, keystone_v3
    $swift_auth_url                       = undef,
    $swift_tenant                         = undef,
    $swift_username                       = undef,
    $swift_password                       = undef,
    $swift_domain_id                      = undef,
    $swift_domain_name                    = 'default',
    $swift_region_name                    = 'RegionOne',
    $s3_type                              = 'amazon_s3',         ##Other values: ceph_s3, minio_s3
    $s3_accesskey                         = undef,
    $s3_secretkey                         = undef,
    $s3_region_name                       = undef,
    $s3_bucket                            = undef,
    $s3_endpoint_url                      = undef,
    $s3_ssl_enabled                       = 'False',
    $s3_signature_version                 = 's3v4',
) {


    $contego_user                         = 'nova'
    $contego_group                        = 'nova'
    $contego_conf_file                    = "/etc/tvault-contego/tvault-contego.conf"
    $contego_groups                       = ['kvm','qemu','disk']
    $vault_data_dir                       = "/var/triliovault-mounts"
    $vault_data_dir_old                   = "/var/triliovault"
    $contego_dir                          = "/home/tvault"
    $contego_virtenv_dir                  = "${contego_dir}/.virtenv"
    $log_dir                              = "/var/log/nova"
    $contego_bin                          = "${contego_virtenv_dir}/bin/tvault-contego"
    $contego_python                       = "${contego_virtenv_dir}/bin/python"
    $config_files                         = "--config-file=${nova_dist_conf_file} --config-file=${nova_conf_file} --config-file=${contego_conf_file}"

  
    if $redhat_openstack_version == '9' {
           $openstack_release = 'mitaka'
    }
    elsif $redhat_openstack_version == '10' {
           $openstack_release = 'newton'
    }
    else {
           $openstack_release = 'premitaka'
    }


##Set object_store_ext

    if $backup_target_type == 'swift' {
        $contego_ext_object_store = "${contego_virtenv_dir}/lib/python2.7/site-packages/contego/nova/extension/driver/vaultfuse.py"
    }
    elsif $backup_target_type == 's3' {
        $contego_ext_object_store = "${contego_virtenv_dir}/lib/python2.7/site-packages/contego/nova/extension/driver/s3vaultfuse.py"

    }


    $contego_systemd_file_content	= "[Unit]
Description=Tvault contego
After=openstack-nova-compute.service
[Service]
User=nova
Group=nova
Type=simple
ExecStart=${contego_python} ${contego_bin} ${config_files}
TimeoutStopSec=20
KillMode=process
Restart=on-failure
[Install]
WantedBy=multi-user.target
"

    $object_store_systemd_file_content     ="[Unit]
Description=Tvault Object Store
After=tvault-contego.service
[Service]
User=${contego_user}
Group=${contego_group}
Type=simple
ExecStart=${contego_python} ${contego_ext_object_store} --config-file=${contego_conf_file}
TimeoutStopSec=20
KillMode=process
Restart=on-failure
[Install]
WantedBy=multi-user.target"

    $contego_conf_nfs		       = "[DEFAULT]
vault_storage_nfs_export = ${nfs_shares}
vault_storage_nfs_options = ${nfs_options}
vault_storage_type = nfs
vault_data_directory_old = ${vault_data_dir_old}
vault_data_directory = ${vault_data_dir}
log_file = /var/log/nova/tvault-contego.log
debug = False
verbose = True
max_uploads_pending = 3
max_commit_pending = 3
"

    $contego_conf_swift                    = "[DEFAULT]
vault_storage_type = swift-s
vault_storage_nfs_export = TrilioVault
vault_data_directory_old = ${vault_data_dir_old}
vault_data_directory = ${vault_data_dir}
log_file = /var/log/nova/tvault-contego.log
debug = False
verbose = True
max_uploads_pending = 3
max_commit_pending = 3
vault_swift_auth_url = ${swift_auth_url}
vault_swift_username = ${swift_username}
vault_swift_password = ${swift_password}
vault_swift_auth_version = ${swift_auth_version}
vault_swift_domain_id = ${swift_domain_id}
vault_swift_domain_name = ${swift_domain_name}
vault_swift_tenant = ${swift_tenant}
vault_swift_region_name = ${swift_region_name}"

    $contego_conf_amazon_s3               ="[DEFAULT]
vault_storage_type = s3
vault_storage_nfs_export = TrilioVault
vault_data_directory_old = ${vault_data_dir_old}
vault_data_directory = ${vault_data_dir}
log_file = /var/log/nova/tvault-contego.log
debug = False
verbose = True
max_uploads_pending = 3
max_commit_pending = 3
vault_s3_auth_version = DEFAULT
vault_s3_access_key_id = ${s3_accesskey}
vault_s3_secret_access_key = ${s3_secretkey}
vault_s3_region_name = ${s3_region_name}
vault_s3_bucket = ${s3_bucket}"

    $contego_conf_ceph_s3               = "[DEFAULT]
vault_storage_type = s3
vault_storage_nfs_export = TrilioVault
vault_data_directory_old = ${vault_data_dir_old}
vault_data_directory =  ${vault_data_dir}
log_file = /var/log/nova/tvault-contego.log
debug = False
verbose = True
max_uploads_pending = 3
max_commit_pending = 3
vault_s3_auth_version = DEFAULT
vault_s3_access_key_id =  ${s3_accesskey}
vault_s3_secret_access_key = ${s3_secretkey}
vault_s3_region_name = us-east-1
vault_s3_bucket = ${s3_bucket}
vault_s3_endpoint_url = ${s3_endpoint_url}
vault_s3_ssl = ${ssl_enabled}"

    $contego_conf_minio_s3               ="[DEFAULT]
vault_storage_type = s3
vault_storage_nfs_export = TrilioVault
vault_data_directory_old = ${vault_data_dir_old}
vault_data_directory = ${vault_data_dir}
log_file = /var/log/nova/tvault-contego.log
debug = False
verbose = True
max_uploads_pending = 3
max_commit_pending = 3
vault_s3_auth_version = DEFAULT
vault_s3_access_key_id = ${s3_accesskey}
vault_s3_secret_access_key = ${s3_secretkey}
vault_s3_region_name = us-east-1
vault_s3_bucket = ${s3_bucket}
vault_s3_endpoint_url = ${s3_endpoint_url}
vault_s3_signature_version = ${s3_signature_version}
vault_s3_support_empty_dir = True
vault_s3_ssl =  ${ssl_enabled}"



    class {'trilio::contego::contego_install': }
    class {'trilio::contego::contego_postinstall': }
    class {'trilio::contego::contego_service': }

}
