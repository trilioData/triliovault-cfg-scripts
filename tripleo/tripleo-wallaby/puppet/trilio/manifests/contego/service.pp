class trilio::contego::service inherits trilio::contego {

    require trilio::contego::install
    require trilio::contego::postinstall
    require trilio::contego::cgroup   

    if ($backup_target_type == 'swift') or ($backup_target_type == 's3') {
        service { 'tvault-object-store':
            ensure     => running,
            enable     => true,
            hasstatus  => true,
            hasrestart => true,
            subscribe  => [Exec['daemon_reload_for_contego'], File['/etc/tvault-contego/tvault-contego.conf']],
            before     => Service['tvault-contego'],
         } 
    }

    service { 'tvault-contego':
        ensure     => running,
        enable     => true,
        hasstatus  => true,
        hasrestart => true,
        subscribe  => File['/etc/tvault-contego/tvault-contego.conf']
    }

}
