class trilio::contego::contego_postinstall inherits trilio::contego {
  
    require trilio::contego::contego_install   
## Adding passwordless sudo access to 'nova' user
    file { "/etc/sudoers.d/${contego_user}":
        ensure => present,
    }->
    file_line { 'Adding passwordless sudo access to nova user':
        path   => "/etc/sudoers.d/${contego_user}",
        line   => "${contego_user} ALL=(ALL) NOPASSWD: ALL",
    }


##Ensure contego log directory /var/log/nova
    file { "/var/log/nova/":
        ensure => 'directory',
        owner  => $contego_user,
        group  => $contego_group,
    }


##Create /etc/tvault-contego/ directory and tvault-contego.conf
    file { '/etc/tvault-contego/':
        ensure => 'directory',
    }

##Create contego conf file

    if $backup_target_type == 'nfs' {
        file { "/etc/tvault-contego/tvault-contego.conf":
            ensure  => present,
            content => $contego_conf_nfs,
        }    
    }
    elsif $backup_target_type == 'swift' {
        file { "/etc/tvault-contego/tvault-contego.conf":
            ensure  => present,
            content => $contego_conf_swift,
        }
    }
    elsif $backup_target_type == 's3' {
        if $s3_type == 'amazon_s3' {
            file { "/etc/tvault-contego/tvault-contego.conf":
                ensure  => present,
                content => $contego_conf_amazon_s3,
            }    
        }
        elsif $s3_type == 'ceph_s3' {
            file { "/etc/tvault-contego/tvault-contego.conf":
                ensure  => present,
                content => $contego_conf_ceph_s3,
            }    
        }
        elsif $s3_type == 'minio_s3' {
            file { "/etc/tvault-contego/tvault-contego.conf":
                ensure  => present,
                content => $contego_conf_minio_s3,
            }
        }
        else {
            fail("s3_type is not valid")
        }
    }
    else {
         fail("backup_target_type is not valid")
    }

##Create log rorate file for contego log rotation: /etc/logrotate.d/tvault-contego
    file { '/etc/logrotate.d/tvault-contego':
        source  => 'puppet:///modules/trilio/log_rotate_conf',
    }

##Create systemd file for tvault-contego service: /etc/systemd/system/tvault-contego.service

    file { '/etc/systemd/system/tvault-contego.service':
        ensure  => present,
        content => $contego_systemd_file_content,
    }


     if ($backup_target_type == 'swift') or ($backup_target_type == 's3') {
         file { '/etc/systemd/system/tvault-object-store.service':
             ensure  => present,
             content => $object_store_systemd_file_content,
         }

         exec { 'daemon_reload_for_object_store':
             cwd         => '/tmp',
             command     => 'systemctl daemon-reload',
             path        => ['/usr/bin', '/usr/sbin',],
             subscribe   => File['/etc/systemd/system/tvault-object-store.service'],
             notify      => [Service['tvault-contego'], Service['tvault-object-store']],
             refreshonly => true,
          }

     }


##Perform daemon reload if any changes happens in contego systemd file
    exec { 'daemon_reload_for_contego':
        cwd         => '/tmp',
        command     => 'systemctl daemon-reload',
        path        => ['/usr/bin', '/usr/sbin',],
        subscribe   => File['/etc/systemd/system/tvault-contego.service'],
        notify      => Service['tvault-contego'],
        refreshonly => true,
    }


}
