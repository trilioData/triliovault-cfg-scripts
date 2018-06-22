class trilio::api (
     $tvault_virtual_ip    = undef,
     $tvault_version       = undef
){

    exec { 'install_pip':
        command => 'easy_install http://${tvault_virtual_ip}:8081/packages/pip-7.1.2.tar.gz',
        cwd     => "/tmp/",
        unless  => '/usr/bin/which pip',
        provider => shell,
        path    => ['/usr/bin','/usr/sbin'],
    }

    exec {'tvault-contego-api':
        command  => "yes | pip install http://${tvault_virtual_ip}:8081/packages/tvault-contego-api-${tvault_version}.tar.gz",
        require  => Exec['install_pip'],
        path     => ['/usr/bin', '/usr/sbin'],
        notify   => Service['openstack-nova-api'],
    }   


    service { 'openstack-nova-api':
        ensure      => running,
        enable      => true,
        hasstatus   => true,
        hasrestart  => true,
    }
 

}
