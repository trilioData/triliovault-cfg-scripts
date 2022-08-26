class trilio {

    class {'trilio::contego':
        nova_conf_file			=> '/etc/nova/nova.conf',
        nova_dist_conf_file	        => '/usr/share/nova/nova-dist.conf',
        backup_target_type              => 's3',
        tvault_appliance_ip		=> '192.168.1.26',
        redhat_openstack_version        => '9',
        s3_type                         => 'amazon_s3',         ##Other values: ceph_s3, minio_s3
        s3_accesskey                    => '',
        s3_secretkey                    => '',
        s3_region_name                  => 'us-east-2',
        s3_bucket                       => '',
        s3_endpoint_url                 => undef,
        s3_ssl_enabled                  => 'True',
        s3_signature_version            => 's3v4',
    } 

}
