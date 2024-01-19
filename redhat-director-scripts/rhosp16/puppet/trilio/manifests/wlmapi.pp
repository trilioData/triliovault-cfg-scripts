class trilio::wlmapi ( 
  $password,
  $port                            = '8780',
  $ssl_port                        = '13781',
  $enable_ssl                      = false,
  $oslomsg_rpc_proto               = hiera('oslo_messaging_rpc_scheme', 'rabbit'),
  $oslomsg_rpc_hosts               = any2array(hiera('oslo_messaging_rpc_node_names', undef)),
  $oslomsg_rpc_password            = hiera('oslo_messaging_rpc_password'),
  $oslomsg_rpc_port                = hiera('oslo_messaging_rpc_port', '5672'),
  $oslomsg_rpc_username            = hiera('oslo_messaging_rpc_user_name', 'guest'),
  $oslomsg_rpc_use_ssl             = hiera('oslo_messaging_rpc_use_ssl', '0'),
  $oslomsg_notify_proto            = hiera('oslo_messaging_notify_scheme', 'rabbit'),
  $oslomsg_notify_hosts            = any2array(hiera('oslo_messaging_notify_node_names', undef)),
  $oslomsg_notify_password         = hiera('oslo_messaging_notify_password'),
  $oslomsg_notify_port             = hiera('oslo_messaging_notify_port', '5672'),
  $oslomsg_notify_username         = hiera('oslo_messaging_notify_user_name', 'guest'),
  $oslomsg_notify_use_ssl          = hiera('oslo_messaging_notify_use_ssl', '0'),
  $memcached_ips                   = hiera('memcached_node_ips', undef),
  $memcached_hosts                 = hiera('memcached_node_names', []),
  $memcached_port                  = hiera('memcached_authtoken_port', 11211),
  $memcached_ipv6                  = hiera('memcached_ipv6', false),
  $memcache_security_strategy      = hiera('memcached_authtoken_security_strategy', undef),
  $secret_key                      = hiera('memcached_authtoken_secret_key', undef),
  $my_ip                           = undef,	  
  $database_connection             = undef,
  $cloud_admin_user_name           = undef,
  $cloud_admin_domain_name         = undef,
  $cloud_admin_password,
  $cloud_admin_project_name        = undef,
  $keystone_username               = 'triliovault',
  $project_domain_name             = 'Default',
  $project_name                    = 'service',
  $user_domain_name                = 'Default',
  $keystone_internal_auth_uri      = undef,
  $keystone_internal_auth_url      = undef,
  $keystone_admin_auth_uri         = undef,
  $keystone_admin_auth_url         = undef,
  $keystone_public_auth_uri        = undef,
  $keystone_public_auth_url        = undef,
  $neutron_internal_auth_url       = undef,
  $neutron_admin_auth_url          = undef,
  $neutron_public_auth_url         = undef,
  $nova_internal_auth_url          = undef,
  $nova_admin_auth_url             = undef,
  $nova_public_auth_url            = undef,
  $cinder_internal_auth_url        = undef,
  $cinder_admin_auth_url           = undef,
  $cinder_public_auth_url          = undef,
  $glance_internal_auth_url        = undef,
  $glance_admin_auth_url           = undef,
  $glance_public_auth_url          = undef,
  $region_name                     = 'regionOne',
  $notification_driver             = 'messagingv2',
  $enable_proxy_headers_parsing    = false,
  $dmapi_workers                   = 16,
  $interface                        = 'internal',
  $trustee_role                     = 'creator',
  $vault_data_dir                   = "/var/lib/nova/triliovault-mounts",
  $backup_target_type              = 'nfs',
  $nfs_shares                      = undef,
  $nfs_options                     = 'nolock,soft,vers=3,timeo=180,intr,lookupcache=none',
  $s3_type                         = 'amazon_s3',
  $s3_accesskey                    = undef,
  $s3_secretkey                    = undef,
  $s3_region_name                  = undef,
  $s3_bucket                       = undef,
  $s3_endpoint_url                 = undef,
  $s3_signature_version            = 'default',
  $s3_auth_version                 = 'DEFAULT',
  $s3_ssl_enabled                  = 'False',
  $nfs_map                         = {},
  $multi_ip_nfs_enabled            = false,
  $auth_host_internal              = undef,
  $auth_port_internal              = undef,
  $auth_protocol_internal          = undef,
  $auth_host_admin                 = undef,
  $auth_port_admin                 = undef,
  $auth_protocol_admin             = undef,
  $auth_host_public                = undef,
  $auth_port_public                = undef,
  $auth_protocol_public            = undef,
  $vcenter_url                     = undef,
  $vcenter_username                = undef,
  $vcenter_password                = undef,
  $vcenter_nossl                   = true,
  $vcenter_cert_file_name          = 'default-vcenter-cert',
  $step                            = lookup('step'),
  $s3_ssl_verify                   = true,
) {
    tag 'wlmapiconfig'
    
      class {'trilio::wlmapi::config':}
}
