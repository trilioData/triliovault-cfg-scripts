class trilio::contego::validate inherits trilio::contego {

    exec { 'install_pip':
        command => "easy_install http://${tvault_virtual_ip}:8081/packages/pip-7.1.2.tar.gz",
        cwd     => "/tmp/",
        unless  => '/usr/bin/which pip',
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }


/*    if $backup_target_type == 'nfs' {
       $nfs_shares_list.each |Integer $index, String $nfs_share| {
       
            file { "/tmp/test_dir_${index}":
                ensure => "directory",
            }->

            exec { "mount nfs share: ${nfs_share}":
                command => "mount -t nfs ${nfs_share} /tmp/test_dir_${index}",
                path    => ['/usr/bin','/usr/sbin'],
                timeout => 10,
            }->

            exec { "unmount nfs share: ${index}":
                command => "umount /tmp/test_dir_${index}",
                path    => ['/usr/bin','/usr/sbin'],
                timeout => 20,
            }

        }
    } */
    if $backup_target_type == 'swift' {
         package { 'python-swiftclient':
             ensure      => present,
             provider    => pip,
             require     => Exec['install_pip'],
         }
         if $swift_auth_version == 'tempauth' {
             exec {'test swift tempauth credentials':
                 command  => "swift -A ${swift_auth_url} -U ${swift_username} -K ${swift_password} list",
                 path     => ['/usr/bin','/usr/sbin', '/usr/local/bin','/usr/local/sbin'],
             }
         }
         elsif $swift_auth_version == 'keystone_v2' {
             $swift_v2_command = "swift --os-auth-url ${swift_auth_url} \
             --os-tenant-name ${swift_tenant} --os-username ${swift_username} --os-password ${swift_password} list "

             exec {'test swift keystone v2 credentials':
                 command  => "${swift_v2_command}",
                 path     => ['/usr/bin','/usr/sbin', '/usr/local/bin','/usr/local/sbin'],
             }


         }
         elsif $swift_auth_version == 'keystone_v3' {
              $swift_v3_command = "swift --os-auth-url ${swift_auth_url} --auth-version 3 \
              --os-project-name ${swift_tenant} --os-project-domain-name ${swift_domain_name} \
              --os-username ${swift_username} --os-user-domain-name ${swift_domain_name}  \
              --os-password ${swift_password} list"

              exec { 'test swift keystonev3 credentials':
                  command  => "${swift_v3_command}",
                  path     => ['/usr/bin','/usr/sbin', '/usr/local/bin','/usr/local/sbin'],
              }
         }
         else {
              fail("Invalid swift_auth_version provided: ${swift_auth_version}")
         }
   
    }
    elsif $backup_target_type == 's3' {
         package { 'boto':
             ensure      => present,
             provider    => pip,
             require     => Exec['install_pip'],
         } ->
         
  
         if $s3_type == 'amazon_s3' {
             file { "copy test_s3.py file":
                 path   => "/tmp/test_s3.py",
                 source => 'puppet:///modules/trilio/test_s3.py',
                 mode   => "766",
             }->
             exec { 'test amazon s3 credentials':
                  command  => "python /tmp/test_s3.py ${s3_accesskey} ${s3_secretkey}",
                  path     => ['/usr/bin','/usr/sbin', '/usr/local/bin','/usr/local/sbin'],
             }

         }
         elsif $s3_type == 'ceph_s3' {
             exec { 'test ceph s3 credentials':
                  command  => "swift -A ${s3_endpoint_url} -U ${$s3_accesskey} -K ${s3_secretkey} list",
                  path     => ['/usr/bin','/usr/sbin', '/usr/local/bin','/usr/local/sbin'],
             }
         }
         elsif $s3_type == 'minio_s3' {

             file { "copy minio client file":
                 path   => "/tmp/mc",
                 source => 'puppet:///modules/trilio/mc',
                 mode   => "766",
             }->

             exec { 'configure minio s3 credentials':
                  command  => "/tmp/mc config host add minio ${s3_endpoint_url}  ${s3_accesskey} ${s3_secretkey} ${s3_signature_version}",
                  path     => ['/usr/bin','/usr/sbin', '/usr/local/bin','/usr/local/sbin'],
             }->
             exec { 'test minio s3 credentials':
                  command  => "/tmp/mc ls",
                  path     => ['/usr/bin','/usr/sbin', '/usr/local/bin','/usr/local/sbin'],
             }

        
         }
         else {
              fail("Invalid s3_type provided: ${s3_type}")
         }
    }
/*    else {
         fail("Invalid backup_target_type: ${backup_target_type}")
    }*/

  
}
