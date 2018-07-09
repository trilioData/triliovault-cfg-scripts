class trilio::contego::install inherits trilio::contego {
  
    require trilio::contego::validate
    notify { $openstack_release: } 

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
    }->
     file { "/var/triliovault":
        ensure => 'directory',
        mode =>  0777,
        owner  => $contego_user,
        group  => $contego_group,
    }->

     file { "/var/triliovault-mounts":
        ensure => 'directory',
        mode =>  0777,
        owner  => $contego_user,
        group  => $contego_group,
    }->

    if($contego_installed_version != $tvault_version){
        exec { 'Clean old virtual env':
             command => "rm -rf /home/tvault",
        }->

        file { '/home/tvault-contego-virtenv.tar.gz':
            ensure  => 'present',
     	    mode    => '0755',
	    source  => 'puppet:///modules/trilio/newton/tvault-contego-virtenv.tar.gz',
        }->
      
        exec { 'Deploy new virtual env':
             command => "tar -xzf tvault-contego-virtenv.tar.gz",
             cwd     => "/home/",
             require => File['/home/tvault/', '/home/tvault-contego-virtenv.tar.gz']
        }

    }

    package { 'tvault-contego':
        ensure => latest,
        provider => 'rpm',
        source => "http://${tvault_virtual_ip}/triliovault-datamover.noarch.rpm",
        notify => Service['tvault-contego'],
    }

}
