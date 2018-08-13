class trilio::contego::config inherits trilio::contego {


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

}
