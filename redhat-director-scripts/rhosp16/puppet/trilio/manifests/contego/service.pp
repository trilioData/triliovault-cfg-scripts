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
            subscribe  => [Exec['daemon_reload_for_contego'], File['/etc/triliovault-datamover/triliovault-datamover.conf']],
            before     => Service['triliovault-datamover'],
         } 
    }

    service { 'triliovault-datamover':
        ensure     => running,
        enable     => true,
        hasstatus  => true,
        hasrestart => true,
        subscribe  => File['/etc/triliovault-datamover/triliovault-datamover.conf']
    }

}
