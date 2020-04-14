class trilio::horizon (
    $horizon_dir                        = '/usr/share/openstack-dashboard/',
){

    package { 'python-workloadmgrclient':
        ensure   => present,
        provider => 'yum',
        notify   => Service['httpd'],
    }->

    package { 'tvault-horizon-plugin':
        ensure   => present,
        provider => 'yum',
        notify   => Service['httpd'],
    }->

    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_panel_group.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_panel_group.py',
        notify => Service['httpd'],
    }->
    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_admin_panel_group.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_admin_panel_group.py',
        notify => Service['httpd'],
    }->
    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_panel.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_panel.py',
        notify => Service['httpd'],
    }->

    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_settings_panel.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_settings_panel.py',
        notify => Service['httpd'],
    }->

    file { "${horizon_dir}/openstack_dashboard/local/enabled/tvault_admin_panel.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_admin_panel.py',
        notify => Service['httpd'],
    }->

    file { "/tmp/sync_static.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/sync_static.py',
        before => Exec['sync_static'],
    }->

    file { "${horizon_dir}/openstack_dashboard/templatetags/tvault_filter.py":
        ensure => 'present',
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        source => 'puppet:///modules/trilio/tvault_filter.py',
        notify => Service['httpd'],
    }->
   
    exec { 'sync_static':
        cwd     => "${horizon_dir}",
        command => "${horizon_dir}/manage.py shell < /tmp/sync_static.py &> /dev/null",
        path    => ['/usr/bin','usr/sbin'],
        refreshonly => true,
        subscribe => Service['httpd'],
    }

}
