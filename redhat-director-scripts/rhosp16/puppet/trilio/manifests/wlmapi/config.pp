class trilio::wlmapi::config inherits trilio::wlmapi {
    tag 'wlmapiconfig'


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

      file { '/etc/triliovault-wlm/':
          ensure => 'directory',
      }->
      file { '/etc/triliovault-object-store/':
          ensure => 'directory',
      }->
      file { "/etc/triliovault-wlm/triliovault-wlm.conf":
          ensure  => present,
          content => template('trilio/triliovault_wlm_conf.erb'),
      }->
      file { "/etc/triliovault-datamover/s3-cert.pem":
          ensure => 'present',
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
          source => 'puppet:///modules/trilio/s3-cert.pem',
      }->
      file { "/etc/triliovault-datamover/triliovault-wlm-ids.conf":
          ensure => 'present',
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
          source => 'puppet:///modules/trilio/triliovault_wlm_ids.conf',
      }->
      file { "/etc/triliovault-wlm/api-paste.ini":
          ensure  => present,
          content => template('trilio/api_paste_ini.erb'),
      }->
      file { "/etc/triliovault-object-store/triliovault-object-store.conf":
          ensure  => present,
          content => template('trilio/triliovault_object_store_conf.erb'),
      }->
      file { "/etc/triliovault-wlm/wlm_logging.conf":
          ensure  => present,
          content => template('trilio/wlm_logging_conf.erb'),
      }
      file { "/etc/triliovault-object-store/object_store_logging.conf":
          ensure  => present,
          content => template('trilio/object_store_logging_conf.erb'),
      }

}
