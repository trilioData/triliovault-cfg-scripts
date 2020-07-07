class trilio::contego::config inherits trilio::contego {
    tag 'dmconfig'


##Create /etc/tvault-contego/ directory and tvault-contego.conf
    file { '/etc/tvault-contego/':
        ensure => 'directory',
    }

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
                content => template('trilio/contego_ceph_s3_conf.erb'),
            }    
        }
        else {
            fail("s3_type is not valid")
        }
    }
    else {
         fail("backup_target_type is not valid")
    }

    file { "/etc/tvault-contego/s3-cert.pem":
        ensure => 'present',
        owner  => '42436',
        group  => '42436',
        mode   => '0644',
        source => 'puppet:///modules/trilio/s3-cert.pem',
    }

}