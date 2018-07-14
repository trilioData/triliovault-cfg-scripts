class trilio::contego::install inherits trilio::contego {
  

    user { 'Add_nova_user_to_system_groups':
        name   => $contego_user,
        ensure => present,
        gid    => $contego_group,
        groups => $contego_groups,
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

    package { 'tvault-contego':
        ensure   => present,
        provider => 'yum',
        notify   => Service['tvault-contego'],
    }

}
