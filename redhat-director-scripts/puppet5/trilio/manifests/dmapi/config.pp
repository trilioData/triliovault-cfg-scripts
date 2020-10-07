class trilio::dmapi::config inherits trilio::dmapi {
    tag 'dmapiconfig'


      $oslomsg_rpc_use_ssl_real = sprintf('%s', bool2num(str2bool($oslomsg_rpc_use_ssl)))
      $oslomsg_notify_use_ssl_real = sprintf('%s', bool2num(str2bool($oslomsg_notify_use_ssl)))

      $default_transport_url = os_transport_url({
        'transport' => $oslomsg_rpc_proto,
        'hosts'     => $oslomsg_rpc_hosts,
        'port'      => $oslomsg_rpc_port,
        'username'  => $oslomsg_rpc_username,
        'password'  => $oslomsg_rpc_password,
        'ssl'       => $oslomsg_rpc_use_ssl_real,
      })

      $notification_transport_url = os_transport_url({
        'transport' => $oslomsg_notify_proto,
        'hosts'     => $oslomsg_notify_hosts,
        'port'      => $oslomsg_notify_port,
        'username'  => $oslomsg_notify_username,
        'password'  => $oslomsg_notify_password,
        'ssl'       => $oslomsg_notify_use_ssl_real,
      })

      $memcached_servers = join(suffix(any2array(normalize_ip_for_uri($memcached_ips)), ':11211'), ',')

      file { '/etc/dmapi/':
          ensure => 'directory',
      } ->
      file { "/etc/dmapi/dmapi.conf":
          ensure  => present,
          content => template('trilio/dmapi.erb'),
      }

}      