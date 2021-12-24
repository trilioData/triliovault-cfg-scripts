class trilio::horizon (
    $horizon_dir                        = '/etc/openstack-dashboard',
){

  tag 'triliohorizonconfig'

    file { "${horizon_dir}/":
        ensure => 'directory',
    }->
    file { "${horizon_dir}/local_settings":
        ensure  => present,
        content => template('trilio/local_settings.erb'),
    }   

}
