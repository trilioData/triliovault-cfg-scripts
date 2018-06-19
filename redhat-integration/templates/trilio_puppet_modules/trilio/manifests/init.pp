class trilio (
  $nova_conf_file                       = '/etc/nova/nova.conf',
  $nova_dist_conf_file                  = '/usr/share/nova/nova-dist.conf',
  $nova_compute_filters_file            = '/usr/share/nova/rootwrap/compute.filters',
  $nfs_shares                           = '192.168.2.35:/mnt/tvault',
  $nfs_options                          = '',
  $tvault_appliance_ip                  = '192.168.2.125',
) {

    file {'/var/log/trilio.log':
       content => "This file is created by trilio scripts",
    }

    file {'/tmp/trilio.log':
       content => "This file is created by trilio scripts",
    }


}
