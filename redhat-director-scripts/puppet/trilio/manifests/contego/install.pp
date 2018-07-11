class trilio::contego::install inherits trilio::contego {
  
    require trilio::contego::validate

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
    }

    if $contego_installed_version != $tvault_version {

        file { 'Clean old virtual env':
             path   => '/home/tvault/.virtenv/',
             ensure => absent,
        }->

        file { '/home/tvault/tvault-contego-virtenv.tar.gz':
            ensure  => 'present',
     	    mode    => '0755',
	    source  => 'puppet:///modules/trilio/newton/tvault-contego-virtenv.tar.gz',
            require => File['/home/tvault']
        }->
      
        exec { 'Deploy new virtual env':
             command => "tar -xzf tvault-contego-virtenv.tar.gz",
             cwd     => "/home/tvault/",
             require => File['/home/tvault/tvault-contego-virtenv.tar.gz'],
             path    => ['/usr/bin','/bin'],
        }

    }

    package { 'tvault-contego':
        ensure   => latest,
        provider => 'yum',
        notify   => Service['tvault-contego'],
    }

}
