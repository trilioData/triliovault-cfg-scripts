class trilio::config (
    $tvault_version                       = undef,
    $redhat_openstack_version             = '10',
    $configurator_node_ip                 = undef,
    $configurator_username                = 'admin',
    $configurator_password                = 'password',
    $controller_nodes                     = undef,
    $tvault_virtual_ip                    = undef,
    $name_server                          = undef,
    $domain_search_order                  = undef,
    $ntp_enabled                          = 'on',
    $ntp_servers                          = '0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org',
    $timezone                             = 'Etc/UTC',
    $keystone_admin_url                   = undef,
    $keystone_public_url                  = undef,
    $admin_username                       = undef,
    $admin_password                       = undef,
    $admin_tenant_name                    = undef,
    $region_name                          = undef,
    $domain_id                            = undef,
    $trustee_role                         = '_member_',
    $backup_target_type                   = undef,
    $storage_nfs_export                   = undef,
    $nfs_options                          = 'nolock,soft,timeo=180,intr',
    $swift_auth_version                   = undef,
    $swift_auth_url                       = undef,
    $swift_username                       = undef,
    $swift_password                       = undef,
    $s3_type                              = undef,
    $s3_accesskey                         = undef,
    $s3_secretkey                         = undef,
    $s3_bucket                            = undef,
    $s3_region_name                       = undef,
    $s3_endpoint_url                      = undef,
    $s3_ssl_enabled                       = False,
    $s3_signature_version                 = 's3v4',
    $enable_tls                           = 'off',
    $cert_file_path                       = undef,
    $privatekey_file_path                 = undef,
    $import_workloads                     = 'off',
){

    $create_file_system="off"
    $storage_local_device="/dev/sdb"
    $_cert=""
    $_private_key=""
    if $enable_tls == "on" {
       $_cert=file($cert_file_path)
       $_private_key=file($privatekey_file_path)
    }

    exec { 'trilio configuration: login to configurator':
        command => "curl -k --cookie-jar $cookie --data 'username=$configurator_username&password=$configurator_password' 'https://$configurator_node_ip/login'",
        cwd     => "/tmp/",
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }->	
	
    exec { 'trilio configuration: configure openstack':
        command => "curl -k --cookie $cookie --data 'triliovault-hostnames=$controller_nodes&virtual-ip=$tvault_virtual_ip& admin-username=$admin_username&admin-password=$admin_password&admin-tenant-name=$admin_tenant_name &keystone-admin-url=$keystone_admin_url&keystone-public-url=$keystone_public_url&name-server=$name_server&domain-search-order =$domain_search_order&region-name=$region_name&backup_target_type=$backup_target_type&create-file-system=$create_file_system&storage-local-device=$storage_local_device&storage-nfs-export=$storage_nfs_export&swift-auth-version=$swift_auth_version&swift-auth-url =$swift_auth_url&domain-name=$domain_id&ntp-enabled=$ntp_enabled&ntp-servers=$ntp_servers&timezone=$timezone &trustee-role=$trustee_role&swift-username =$swift_username&swift-password =$swift_password&enable_tls=$enable_tls&cert=$_cert &privatekey=$_private_key&s3-access-key=$s3_access_key&s3-secret-key=$s3_secret_key&s3-region=$s3_region_name&s3-bucket =$s3_bucket&s3-endpoint-url=$s3_endpoint_url&s3-use-ssl=$s3_ssl_enabled&s3-backend-type=$s3_type&workloads-import=$import_workloads ' 'https://$configurator_node_ip /configure_openstack'",
        cwd     => "/tmp/",
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }->

    exec { 'trilio configuration: populate variables':
        command => "curl -k --cookie '$cookie' 'https://$configurator_node_ip/populate_variables'",
        cwd     => "/tmp/",
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }->

    exec { 'trilio configuration: configure host':
        command => "curl -k --cookie '$cookie' 'https://$configurator_node_ip/configure_host'",
        cwd     => "/tmp/",
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }->
	
    exec { 'trilio configuration: configure workloadmgr':
        command => "curl -k --cookie '$cookie' 'https://$configurator_node_ip/configure_workloadmgr'",
        cwd     => "/tmp/",
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }->

    exec { 'trilio configuration: register workload types':
        command => "curl -k --cookie '$cookie' 'https://$configurator_node_ip/register_workloadtypes'",
        cwd     => "/tmp/",
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }

}
