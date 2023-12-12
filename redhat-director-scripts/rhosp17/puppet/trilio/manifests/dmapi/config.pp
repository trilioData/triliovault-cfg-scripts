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

      $memcached_hosts_real = any2array(pick($memcached_ips, $memcached_hosts))
      if $step >= 3 {
            if $memcached_ipv6 or $memcached_hosts_real[0] =~ Stdlib::Compat::Ipv6 {
            $memcache_servers = $memcached_hosts_real.map |$server| { "inet6:[${server}]:${memcached_port}" }
            } else {
            $memcache_servers = suffix($memcached_hosts_real, ":${memcached_port}")
            }

            if $secret_key {
            $hashed_secret_key = sha256("${secret_key}+triliovault_datamover_api")
            } else {
            $hashed_secret_key = undef
            }
      }
      file { '/etc/triliovault-datamover/':
          ensure => 'directory',
          mode   => '0644',
      } ->
      file { "/etc/triliovault-datamover/triliovault-datamover-api.conf":
          ensure  => present,
          content => template('trilio/triliovault_datamover_api_conf.erb'),
          mode   => '0644',
      }->
      file { "/etc/triliovault-datamover/datamover_api_logging.conf":
          ensure  => present,
          content => template('trilio/datamover_api_logging_conf.erb'),
          mode   => '0644',
      }
      file { '/opt/triliovault':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { "/opt/triliovault/start_triliovault_datamover_api.sh":
          ensure  => present,
          content => template('trilio/start_triliovault_datamover_api_sh.erb'),
          mode   => '0755',
      }


}      
