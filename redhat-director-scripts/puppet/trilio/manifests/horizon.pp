class trilio::horizon (
    $tvault_virtual_ip                  = undef, 
    $horizon_dir                        = '/usr/share/openstack-dashboard/',
    $tvault_version                     = undef,
){


    exec {'python-workloadmgrclient':
        command  => "yes | pip install http://${tvault_virtual_ip}:8081/packages/python-workloadmgrclient-${tvault_version}.tar.gz",
        require  => Exec['install_pip'],
        before   => Exec['tvault-horizon-plugin'],
        path     => ['/usr/bin/', '/usr/sbin'],
    }

    exec {'tvault-horizon-plugin':
        command  => "yes | pip install http://${tvault_virtual_ip}:8081/packages/tvault-horizon-plugin-${tvault_version}.tar.gz",
        require  => Exec['install_pip'],
        path     => ['/usr/bin/', '/usr/sbin'],
        notify   => Service['httpd'],
    }
    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_panel_group.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_panel_group.py',
        before => Service['httpd'],
    }
    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_admin_panel_group.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_admin_panel_group.py',
        before => Service['httpd'],
    }
    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_panel.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_panel.py',
        before => Service['httpd'],
    }

    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_settings_panel.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_settings_panel.py',
        before => Service['httpd'],
    }

    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_admin_panel.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_admin_panel.py',
        before => Service['httpd'],
    }

    file { "/tmp/sync_static.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/sync_static.py',
        before => Exec['sync_static'],
    }

    file { "${horizon_dir}/openstack_dashboard/templatetags/tvault_filter.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_filter.py',
        before => Service['httpd'],
    }
   
    exec { 'sync_static':
        cwd     => "${horizon_dir}",
        command => "${horizon_dir}/manage.py shell < /tmp/sync_static.py &> /dev/null",
        path    => ['/usr/bin','usr/sbin'],
        refreshonly => true,
        require => Service['httpd'],
    }

}
