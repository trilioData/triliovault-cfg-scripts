class trilio::horizon (
    $horizon_dir                        = '/etc/openstack-dashboard',
){

  tag 'triliohorizonconfig'

    file { "${horizon_dir}/local_settings.d":
        ensure => 'directory',
    }->
    file { "Create trilio dashboard file":
        path   => "${horizon_dir}/local_settings.d/_001_trilio_dashboard.py",
        ensure => present,
    }->
    if $barbican_api_enabled  == 'true' {
        file_line { 'set variable OPENSTACK_ENCRYPTION_SUPPORT':
            ensure => present,
            path   => "${horizon_dir}/local_settings.d/_001_trilio_dashboard.py",
            line   => 'OPENSTACK_ENCRYPTION_SUPPORT = True',
        }
    }
    else {
        file_line { 'set variable OPENSTACK_ENCRYPTION_SUPPORT':
            ensure => present,
            path   => "${horizon_dir}/local_settings.d/_001_trilio_dashboard.py",
            line   => 'OPENSTACK_ENCRYPTION_SUPPORT = False',
        }
    }->
    file_line { 'set variable TRILIO_ENCRYPTION_SUPPORT':
        ensure => present,
        path   => "${horizon_dir}/local_settings.d/_001_trilio_dashboard.py",
        line   => 'TRILIO_ENCRYPTION_SUPPORT = False',
    }->
    file_line { 'set variable TRILIO_ENCRYPTION_SUPPORT':
        ensure => present,
        path   => "${horizon_dir}/local_settings.d/_001_trilio_dashboard.py",
        line   => "HORIZON_CONFIG['customization_module'] = 'dashboards.overrides'",
    }

    

}
