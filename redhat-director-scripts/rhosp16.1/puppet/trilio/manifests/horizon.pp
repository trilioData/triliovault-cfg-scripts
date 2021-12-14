class trilio::horizon (
    $horizon_dir                        = '/etc/openstack-dashboard',
){

  tag 'triliohorizonconfig'

    file { "${horizon_dir}/local_settings.d":
        ensure => 'directory',
    }->
    file { "${horizon_dir}/local_settings.d/_002_trilio_dashboard.py":
        ensure  => present,
        content => template('trilio/_002_trilio_dashboard.py.erb'),
    }   

}