class trilio {

    class {'trilio::contego':
        nova_conf_file			=> '/etc/nova/nova.conf',
        nova_dist_conf_file	        => '/usr/share/nova/nova-dist.conf',
        backup_target_type              => 'swift',
        tvault_appliance_ip		=> '192.168.1.26',
        redhat_openstack_version        => '9',
        swift_auth_version              => 'keystone_v2',
        swift_auth_url                  => 'http://192.168.1.21:5000/v2.0',
        swift_tenant                    => 'admin',
        swift_username                  => 'admin',
        swift_password                  => 'password',
        swift_domain_id                 => 'default',
        swift_domain_name               => 'Default',
        swift_region_name               => 'RegionOne',

    } 

}
