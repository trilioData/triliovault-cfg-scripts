class trilio::contego::config inherits trilio::contego {
    tag 'dmconfig'


$backup_targets = [
  {
    backup_target_name    => 'S3_BT1',
    backup_target_type    => 's3',
    is_default            => true,
    s3_type               => 'ceph_s3',
    s3_access_key         => 'ACCESSKEY1',
    s3_secret_key         => 'SECRETKEY1',
    s3_region_name        => 'REGION1',
    s3_bucket             => 'trilio-qa',
    s3_endpoint_url       => 'https://cephs3.triliodata.demo',
    s3_signature_version  => 'default',
    s3_auth_version       => 'DEFAULT',
    s3_ssl_enabled        => false,
    s3_ssl_verify         => true
  },
  {
    backup_target_name    => 'S3_BT2',
    backup_target_type    => 's3',
    is_default            => true,
    s3_type               => 'amazon_s3',
    s3_access_key         => 'ACCESSKEY2',
    s3_secret_key         => 'SECRETKEY2',
    s3_region_name        => 'REGION2',
    s3_bucket             => 'trilio-qa',
    s3_endpoint_url       => 'ENDPOINT_URL2',
    s3_signature_version  => 'default',
    s3_auth_version       => 'DEFAULT',
    s3_ssl_enabled        => true,
    s3_ssl_verify         => true
  },
  {
     backup_target_name => 'NFS_BT3',
     backup_target_type => 'nfs',
     is_default => false,
     nfs_shares => '172.30.1.9:/mnt/rhosptargetnfs',
     nfs_options => 'nolock,soft,timeo=600,intr,lookupcache=none,nfsvers=3,retrans=10'
  },
  {
     backup_target_name => 'NFS_BT4',
     backup_target_type => 'nfs',
     is_default => false,
     nfs_shares => '172.30.1.8:/mnt/rhosptargetnfs',
     nfs_options => 'nolock,soft,timeo=600,intr,lookupcache=none,nfsvers=3,retrans=10'
  }

]


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


    if $vmware_to_openstack_migration_enabled {
      file { '/opt/vmware-vix-disklib-distrib/':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { "/opt/vddk.tar.gz":
          ensure => 'present',
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
          source => "puppet:///modules/trilio/$vddk_file_name",
      }
    }
}

