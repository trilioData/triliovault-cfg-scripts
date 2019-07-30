class trilio {

    class {'trilio::contego':
        nova_conf_file			=> '/etc/nova/nova.conf',
        nova_dist_conf_file	        => '/usr/share/nova/nova-dist.conf',
        backup_target_type              => 'nfs',
        nfs_shares		        => '192.168.1.33:/mnt/tvault',
        nfs_options			=> 'nolock,soft,timeo=180,intr',
        tvault_appliance_ip		=> '192.168.1.26',
        redhat_openstack_version        => '9',
    } 

}
