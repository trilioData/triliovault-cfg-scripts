class trilio::dmapi ( 
  $password,
  $dmapi_port                      = '8784',
  $dmapi_ssl_port                  = '13784',
  $dmapi_enable_ssl                = false,
  $oslomsg_rpc_proto               = hiera('messaging_rpc_service_name', 'rabbit'),
  $oslomsg_rpc_hosts               = any2array(hiera('rabbitmq_node_names', undef)),
  $oslomsg_rpc_password            = hiera('cinder::rabbit_password'),
  $oslomsg_rpc_port                = hiera('cinder::rabbit_port', '5672'),
  $oslomsg_rpc_username            = hiera('cinder::rabbit_userid', 'guest'),
  $oslomsg_notify_proto            = hiera('messaging_notify_service_name', 'rabbit'),
  $oslomsg_notify_hosts            = any2array(hiera('rabbitmq_node_names', undef)),
  $oslomsg_notify_password         = hiera('cinder::rabbit_password'),
  $oslomsg_notify_port             = hiera('cinder::rabbit_port', '5672'),
  $oslomsg_notify_username         = hiera('cinder::rabbit_userid', 'guest'),
  $oslomsg_use_ssl                 = hiera('cinder::rabbit_use_ssl', '0'),
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
  $dmapi_workers                   = 16,
) {
    tag 'dmapiconfig'

      $oslomsg_use_ssl_real = sprintf('%s', bool2num(str2bool($oslomsg_use_ssl)))
      file { '/etc/dmapi/':
          ensure => 'directory',
      }
      $default_transport_url = os_transport_url({
        'transport' => $oslomsg_rpc_proto,
        'hosts'     => $oslomsg_rpc_hosts,
        'port'      => $oslomsg_rpc_port,
        'username'  => $oslomsg_rpc_username,
        'password'  => $oslomsg_rpc_password,
        'ssl'       => $oslomsg_use_ssl_real,
      })

      $notification_transport_url = os_transport_url({
        'transport' => $oslomsg_notify_proto,
        'hosts'     => $oslomsg_notify_hosts,
        'port'      => $oslomsg_notify_port,
        'username'  => $oslomsg_notify_username,
        'password'  => $oslomsg_notify_password,
        'ssl'       => $oslomsg_use_ssl_real,
      })

      $memcached_servers = join(suffix(any2array(normalize_ip_for_uri($memcached_ips)), ':11211'), ',')


    file { "/etc/dmapi/dmapi.conf":
        ensure  => present,
        content => template('trilio/dmapi.erb'),
    }

    file { "Create trilio dashboard file":
        path   => '/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d/_001_trilio_dashboard.py',
        ensure => present,
    }->
    if $barbican_api_enabled  == 'true' {
        file_line { 'set variable OPENSTACK_ENCRYPTION_SUPPORT':
            ensure => present,
            path   => '/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d/_001_trilio_dashboard.py',
            line   => 'OPENSTACK_ENCRYPTION_SUPPORT = True',
        }
    }
    else {
        file_line { 'set variable OPENSTACK_ENCRYPTION_SUPPORT':
            ensure => present,
            path   => '/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d/_001_trilio_dashboard.py',
            line   => 'OPENSTACK_ENCRYPTION_SUPPORT = False',
        }
    }->
    file_line { 'set variable TRILIO_ENCRYPTION_SUPPORT':
        ensure => present,
        path   => '/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.d/_001_trilio_dashboard.py',
        line   => 'TRILIO_ENCRYPTION_SUPPORT = False',
    }
}
