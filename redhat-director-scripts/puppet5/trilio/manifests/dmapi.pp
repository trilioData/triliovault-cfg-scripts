class trilio::dmapi ( 
  $dmapi_port                      = '8784',
  $dmapi_ssl_port                  = '13784',
  $dmapi_enable_ssl                = false,
  $oslomsg_rpc_proto       	   = lookup('messaging_rpc_service_name', 'rabbit'),
  $oslomsg_rpc_hosts       	   = any2array(lookup('rabbitmq_node_names', undef)),
  $oslomsg_rpc_password    	   = lookup('nova::rabbit_password'),
  $oslomsg_rpc_port        	   = lookup('nova::rabbit_port', '5672'),
  $oslomsg_rpc_username    	   = lookup('nova::rabbit_userid', 'guest'),
  $oslomsg_notify_proto    	   = lookup('messaging_notify_service_name', 'rabbit'),
  $oslomsg_notify_hosts    	   = any2array(lookup('rabbitmq_node_names', undef)),
  $oslomsg_notify_password 	   = lookup('nova::rabbit_password'),
  $oslomsg_notify_port     	   = lookup('nova::rabbit_port', '5672'),
  $oslomsg_notify_username 	   = lookup('nova::rabbit_userid', 'guest'),
  $oslomsg_use_ssl         	   = lookup('nova::rabbit_use_ssl', '0'),
  $memcached_ips                   = lookup('memcached_node_ips', undef),
  $my_ip                           = lookup('nova::my_ip', undef),	  
  $database_connection             = lookup('nova::database_connection', undef),
  $api_database_connection         = lookup('nova::api_database_connection', undef),
  $project_domain_name             = lookup('nova::keystone::authtoken::project_domain_name', undef),
  $project_name                    = lookup('nova::keystone::authtoken::project_name', undef),
  $user_domain_name                = lookup('nova::keystone::authtoken::user_domain_name', undef),
  $password                        = lookup('nova::keystone::authtoken::password', undef),
  $auth_url                        = lookup('nova::keystone::authtoken::auth_url', undef),
  $auth_uri                        = lookup('nova::keystone::authtoken::auth_uri', undef),
  $notification_driver             = lookup('nova::notification_driver', undef),
  $enable_proxy_headers_parsing    = lookup('nova::api::enable_proxy_headers_parsing', false),
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
        'ssl'       => $oslomsg_use_ssl,
      })

      $notification_transport_url = os_transport_url({
        'transport' => $oslomsg_notify_proto,
        'hosts'     => $oslomsg_notify_hosts,
        'port'      => $oslomsg_notify_port,
        'username'  => $oslomsg_notify_username,
        'password'  => $oslomsg_notify_password,
        'ssl'       => $oslomsg_use_ssl,
      })

      $memcached_servers = join(suffix(any2array(normalize_ip_for_uri($memcached_ips)), ':11211'), ',')


    file { "/etc/dmapi/dmapi.conf":
        ensure  => present,
        content => template('trilio/dmapi.erb'),
    }
}
