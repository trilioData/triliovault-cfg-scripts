class trilio::dmapi ( 
  $password,
  $dmapi_port                      = '8784',
  $dmapi_ssl_port                  = '13784',
  $dmapi_enable_ssl                = false,
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
  $my_ip                           = undef,	  
  $database_connection             = undef,
  $project_domain_name             = 'Default',
  $project_name                    = 'service',
  $user_domain_name                = 'Default',
  $auth_url                        = undef,
  $auth_uri                        = undef,
  $region_name                     = 'regionOne',
  $notification_driver             = 'messagingv2',
  $enable_proxy_headers_parsing    = false,
) {
    tag 'dmapiconfig'


      file { '/etc/dmapi/':
          ensure => 'directory',
      }
      $default_transport_url = os_transport_url({
        'transport' => $oslomsg_rpc_proto,
        'hosts'     => $oslomsg_rpc_hosts,
        'port'      => $oslomsg_rpc_port,
        'username'  => $oslomsg_rpc_username,
        'password'  => $oslomsg_rpc_password,
        'ssl'       => $oslomsg_rpc_use_ssl,
      })

      $notification_transport_url = os_transport_url({
        'transport' => $oslomsg_notify_proto,
        'hosts'     => $oslomsg_notify_hosts,
        'port'      => $oslomsg_notify_port,
        'username'  => $oslomsg_notify_username,
        'password'  => $oslomsg_notify_password,
        'ssl'       => $oslomsg_notify_use_ssl,
      })

      $memcached_servers = join(suffix(any2array(normalize_ip_for_uri($memcached_ips)), ':11211'), ',')


    file { "/etc/dmapi/dmapi.conf":
        ensure  => present,
        content => template('trilio/dmapi.erb'),
    }
}
