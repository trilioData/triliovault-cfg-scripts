class trilio::contego::install inherits trilio::contego {
  
    require trilio::contego::validate
    notify { $openstack_release: } 
## Adding nova user to system groups
    user { 'Add_nova_user_to_system_groups':
        name   => $contego_user,
        ensure => present,
        gid    => $contego_group,
        groups => $contego_groups,
    }->
    file { "/home/tvault/":
        ensure => 'directory',
        owner  => $contego_user,
        group  => $contego_group,
    }


    file { '/tmp/contego_install.sh':
        ensure  => 'present',
        owner   => root,
        group   => root,
	mode    => '0711',
	source  => 'puppet:///modules/trilio/contego_install.sh',
        require => File["/home/tvault"]
    }->
    exec { 'install_upgrade_datamover':
        command  => "/tmp/contego_install.sh ${contego_dir} ${tvault_virtual_ip} ${openstack_release} > /tmp/contego_install.log",
        provider => shell,
        path     => ['/bin/bash','/usr/bin','/usr/sbin','usr/local/bin'],
        onlyif   => '/usr/bin/test -e /tmp/contego_install.sh',
    }
  
}
