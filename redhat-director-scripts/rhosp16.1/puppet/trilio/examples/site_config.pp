node 'RHEL-newton-controller' {
#	class {'trilio::horizon':
#		tvault_version => '3.0.32',
#   		tvault_virtual_ip  => '192.168.13.3',
#       }



#	class {'trilio::api':
#		tvault_version => '3.0.32',
#		tvault_virtual_ip  => '192.168.13.3',
#	}

    class {'trilio::config':
    tvault_version                       => '3.0.35',
    redhat_openstack_version             => '10',
    configurator_node_ip                 => '192.168.15.32',
    configurator_username                => 'admin',
    configurator_password                => 'password',
    controller_nodes                     => "192.168.15.32=shyam-node1",
    tvault_virtual_ip                    => '192.168.15.38',
    name_server                          => '8.8.8.8',
    domain_search_order                  => 'triliodata.demo',
    ntp_enabled                          => 'on',
    ntp_servers                          => '0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org',
    timezone                             => 'Etc/UTC',
    keystone_admin_url                   => 'http://192.168.1.68:35357/v3',
    keystone_public_url                  => 'http://192.168.1.68:5000/v3',
    admin_username                       => 'admin',
    admin_password                       => 'password',
    admin_tenant_name                    => 'admin',
    region_name                          => 'RegionOne',
    domain_id                            => 'default',
    trustee_role                         => '_member_',
    backup_target_type                   => 'NFS',
    storage_nfs_export                   => '192.168.1.33:/mnt/tvault',
    nfs_options                          => "nolock,soft,timeo=180,intr",
    swift_auth_version                   => undef,
    swift_auth_url                       => undef,
    swift_username                       => undef,
    swift_password                       => undef,
    s3_type                              => undef,
    s3_accesskey                         => undef,
    s3_secretkey                         => undef,
    s3_bucket                            => undef,
    s3_region_name                       => undef,
    s3_endpoint_url                      => undef,
    s3_ssl_enabled                       => False,
    s3_signature_version                 => 's3v4',
    enable_tls                           => 'off',
    cert_file_path                       => undef,
    privatekey_file_path                 => undef,
    import_workloads                     => 'off',
    }
 
}


node 'RHEL-newton-compute' {

	/*class {'trilio::contego':
		tvault_version       => '3.0.32',
                tvault_virtual_ip    => '192.168.13.3',
                nfs_shares           => '192.168.1.33:/mnt/tvault,192.168.1.34:/mnt/tvault',
	}*/
        #$test=file('/tmp/test.txt')
        /*class {'trilio::testfile': 
              test = file('/tmp/test.txt')*/
       # notify { $test: }       


}
