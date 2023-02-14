class trilio::contego::config inherits trilio::contego {
    tag 'dmconfig'


    $oslomsg_rpc_use_ssl_real = sprintf('%s', bool2num(str2bool($oslomsg_rpc_use_ssl)))
    $default_transport_url = os_transport_url({
        'transport' => $oslomsg_rpc_proto,
        'hosts'     => $oslomsg_rpc_hosts,
        'port'      => $oslomsg_rpc_port,
        'username'  => $oslomsg_rpc_username,
        'password'  => $oslomsg_rpc_password,
        'ssl'       => $oslomsg_rpc_use_ssl_real,
      })


    file { '/etc/triliovault-datamover/':
        ensure => 'directory',
        owner  => '42436',
        group  => '42436',
        mode   => '0644',
    }->
    file { "/etc/triliovault-datamover/triliovault-datamover.conf":
        ensure  => present,
        owner  => '42436',
        group  => '42436',
        mode   => '0644',
        content => template('trilio/triliovault_datamover_conf.erb'),
    }->
    file { "/etc/triliovault-datamover/datamover_logging.conf":
        ensure  => present,
        owner  => '42436',
        group  => '42436',
        mode   => '0644',
        content => template('trilio/datamover_logging_conf.erb'),
    }->
    file { "/etc/triliovault-datamover/s3-cert.pem":
        ensure => 'present',
        owner  => '42436',
        group  => '42436',
        mode   => '0644',
        source => 'puppet:///modules/trilio/s3-cert.pem',
    }
    file { "/etc/triliovault-datamover/fuse.conf":
        ensure  => present,
        owner  => '42436',
        group  => '42436',
        mode   => '0644',
        content => template('trilio/fuse.conf.erb'),
    }->
    file { '/opt/triliovault/':
        ensure => 'directory',
        owner  => '42436',
        group  => '42436',
        mode   => '0755',
    }->
    file { "/opt/triliovault/start_triliovault_datamover.sh":
        ensure  => present,
        content => template('trilio/start_triliovault_datamover_sh.erb'),
        owner  => '42436',
        group  => '42436',
        mode   => '0755',
    }
}

