class trilio::api {

    package {'python-pip':
        ensure   => present,
        provider => yum,
    }

    package {'tvault-contego-api':
        ensure   => present,
        provider => pip,
        source   => "http://192.168.1.26:8081/packages/tvault-contego-api-${contego_version}.tar.gz",
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
