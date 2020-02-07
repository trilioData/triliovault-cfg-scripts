class trilio::contego::postinstall inherits trilio::contego {
  
    require trilio::contego::install   

    if $openstack_release == "newton" {
        file { "$contego_dir/.virtenv/lib/python2.7/site-packages/cryptography":
            ensure => 'link',
            target => $which_cryptography,
            force  => yes,
        }

        file { "$contego_dir/.virtenv/lib/python2.7/site-packages/cffi":
            ensure => 'link',
            target => $which_cffi,
            force  => yes,
        }
  
  
        file { "Copy libvirtmod so file":
            source => $which_libvirt,
            path   => "$contego_dir/.virtenv/lib/python2.7/site-packages/libvirtmod.so",
        }
  
        file { 'Copy cffi so file':
            source => $which_cffi_so,
	    path   => "$contego_dir/.virtenv/lib/python2.7/site-packages/_cffi_backend.so",
        }	  
    }



## Adding passwordless sudo access to 'nova' user
    file { "/etc/sudoers.d/triliovault_${contego_user}":
        ensure => present,
    }->
    file_line { 'Adding passwordless sudo access to nova user':
        path   => "/etc/sudoers.d/triliovault_${contego_user}",
        line   => "${contego_user} ALL=(ALL) NOPASSWD: ALL",
    }


##Create /etc/tvault-contego/ directory and tvault-contego.conf
    file { '/etc/tvault-contego/':
        ensure => 'directory',
    }

##Create contego conf file

    if $backup_target_type == 'nfs' {
        file { "/etc/tvault-contego/tvault-contego.conf":
            ensure  => present,
            content => template('trilio/contego_nfs_conf.erb'),
        }    
    }
    elsif $backup_target_type == 's3' {
        if $s3_type == 'amazon_s3' {
            file { "/etc/tvault-contego/tvault-contego.conf":
                ensure  => present,
                content => template('trilio/contego_amazon_s3_conf.erb'),
            }    
        }
        elsif $s3_type == 'ceph_s3' {
            file { "/etc/tvault-contego/tvault-contego.conf":
                ensure  => present,
                content => template('contego_ceph_s3_conf.erb'),
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
        content => template('trilio/contego_systemd_conf.erb'),
    }


     if $backup_target_type == 's3' {
         file { '/etc/systemd/system/tvault-object-store.service':
             ensure  => present,
             content => template('trilio/object_store_systemd_conf.erb'),
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
