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

    package { 'tvault-contego':
        ensure => latest,
        provider => 'rpm',
        source => "/var/tmp/tvault-contego-${tvault_version}-${tvault_release}.noarch.rpm",
        notify => Service['tvault-contego'],
    }

}
