class trilio::api (
     $tvault_virtual_ip    = undef 
){

    package {'python-pip':
        ensure   => present,
        provider => yum,
    }

    package {'tvault-contego-api':
        ensure   => present,
        provider => pip,
        source   => "http://${tvault_virtual_ip}:8081/packages/tvault-contego-api-${tvault_version}.tar.gz",
        require  => Package['python-pip'],
        notify   => Service['openstack-nova-api']
    }

    service { 'openstack-nova-api':
        ensure      => running,
        enable      => true,
        hasstatus   => true,
        hasrestart  => true,
    }
 

}
