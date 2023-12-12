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
 
        $memcached_hosts_real = any2array(pick($memcached_ips, $memcached_hosts))
        if $step >= 3 {
            if $memcached_ipv6 or $memcached_hosts_real[0] =~ Stdlib::Compat::Ipv6 {
            $memcached_servers = $memcached_hosts_real.map |$server| { "inet6:[${server}]:${memcached_port}" }
            } else {
            $memcached_servers = suffix($memcached_hosts_real, ":${memcached_port}")
            }

            if $secret_key {
            $memcache_secret_key = sha256("${secret_key}+triliovault_wlm_api")
            } else {
            $memcache_secret_key = undef
            }
        }

        if !is_service_default($memcached_servers) and !empty($memcached_servers){
            $memcached_servers_array = $memcached_servers ? {
            String  => split($memcached_servers, ','),
            default => $memcached_servers
            }
            $memcached_servers_real = join(any2array(inet6_prefix($memcached_servers_array)), ',')
        } else {
            $memcached_servers_real = $::os_service_default
        }
      file { '/opt/triliovault':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { "/opt/triliovault/start_triliovault_wlm_api.sh":
          ensure  => present,
          content => template('trilio/start_triliovault_wlm_api_sh.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { "/opt/triliovault/start_triliovault_wlm_cron.sh":
          ensure  => present,
          content => template('trilio/start_triliovault_wlm_cron_sh.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { "/opt/triliovault/start_triliovault_wlm_scheduler.sh":
          ensure  => present,
          content => template('trilio/start_triliovault_wlm_scheduler_sh.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { "/opt/triliovault/start_triliovault_wlm_workloads.sh":
          ensure  => present,
          content => template('trilio/start_triliovault_wlm_workloads_sh.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { "/opt/triliovault/create_wlm_cloud_trust.sh":
          ensure  => present,
          content => template('trilio/create_wlm_cloud_trust_sh.erb'),
          mode   => '0755',
      }

      file { '/etc/triliovault-wlm/':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
      }->
      file { '/etc/triliovault-object-store/':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
      }->
      file { "/etc/triliovault-wlm/cloud_admin_rc":
          ensure  => present,
          content => template('trilio/cloud_admin_rc.erb'),
          mode    => '0744',
      }->
      file { "/etc/triliovault-wlm/get_keystone_resources.sh":
          ensure  => present,
          content => template('trilio/get_keystone_resources_sh.erb'),
          mode    => '0744',
      }->
      file { "/etc/triliovault-wlm/triliovault-wlm.conf":
          ensure  => present,
          content => template('trilio/triliovault_wlm_conf.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
      }
      file { "/etc/triliovault-wlm/s3-cert.pem":
          ensure => 'present',
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
          source => 'puppet:///modules/trilio/s3-cert.pem',
      }
      if $vcenter_nossl == false {
        file { "/etc/triliovault-wlm/${vcenter_cert_file_name}":
            ensure => 'present',
            owner  => '42436',
            group  => '42436',
            mode   => '0644',
            source => "puppet:///modules/trilio/${vcenter_cert_file_name}",
        }
      }
      file { "/etc/triliovault-wlm/triliovault-wlm-ids.conf":
          ensure => 'present',
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
          source => 'puppet:///modules/trilio/triliovault_wlm_ids.conf',
      }->
      file { "/etc/triliovault-wlm/api-paste.ini":
          ensure  => present,
          content => template('trilio/api_paste_ini.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
      }->
      file { "/etc/triliovault-wlm/fuse.conf":
          ensure  => present,
          content => template('trilio/fuse.conf.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
      }->
      file { "/etc/triliovault-object-store/triliovault-object-store.conf":
          ensure  => present,
          content => template('trilio/triliovault_object_store_conf.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
      }->
      file { "/etc/triliovault-wlm/wlm_logging.conf":
          ensure  => present,
          content => template('trilio/wlm_logging_conf.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
      }
      file { "/etc/triliovault-object-store/object_store_logging.conf":
          ensure  => present,
          content => template('trilio/object_store_logging_conf.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
      }


}
