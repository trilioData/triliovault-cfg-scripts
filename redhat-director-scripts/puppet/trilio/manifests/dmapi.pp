class trilio::dmapi ( 
  $dmapi_port                      = '8785',
  $is_ssl_enabled                  = hiera('nova::wsgi::apache_api::ssl', false),
  $oslomsg_rpc_proto       	   = hiera('messaging_rpc_service_name', 'rabbit'),
  $oslomsg_rpc_hosts       	   = any2array(hiera('rabbitmq_node_names', undef)),
  $oslomsg_rpc_password    	   = hiera('nova::rabbit_password'),
  $oslomsg_rpc_port        	   = hiera('nova::rabbit_port', '5672'),
  $oslomsg_rpc_username    	   = hiera('nova::rabbit_userid', 'guest'),
  $oslomsg_notify_proto    	   = hiera('messaging_notify_service_name', 'rabbit'),
  $oslomsg_notify_hosts    	   = any2array(hiera('rabbitmq_node_names', undef)),
  $oslomsg_notify_password 	   = hiera('nova::rabbit_password'),
  $oslomsg_notify_port     	   = hiera('nova::rabbit_port', '5672'),
  $oslomsg_notify_username 	   = hiera('nova::rabbit_userid', 'guest'),
  $oslomsg_use_ssl         	   = hiera('nova::rabbit_use_ssl', '0'),
  $memcached_ips                   = hiera('memcached_node_ips', undef),
  $my_ip                           = hiera('nova::my_ip', undef),	  
  $database_connection             = hiera('nova::database_connection', undef),
  $api_database_connection         = hiera('nova::api_database_connection', undef),
  $project_domain_name             = hiera('nova::keystone::authtoken::project_domain_name', undef),
  $project_name                    = hiera('nova::keystone::authtoken::project_name', undef),
  $user_domain_name                = hiera('nova::keystone::authtoken::user_domain_name', undef),
  $password                        = hiera('nova::keystone::authtoken::password', undef),
  $auth_url                        = hiera('nova::keystone::authtoken::auth_url', undef),
  $auth_uri                        = hiera('nova::keystone::authtoken::auth_uri', undef),
  $notification_driver             = hiera('nova::notification_driver', undef),
  $enable_proxy_headers_parsing    = hiera('nova::api::enable_proxy_headers_parsing', false),
) {
    tag 'dmapiconfig'

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

      $memcached_servers = suffix(any2array(normalize_ip_for_uri($memcached_ips)), ':11211')


    file { "/etc/dmapi/dmapi.conf":
        ensure  => present,
        content => template('trilio/dmapi.erb'),
    }
}
