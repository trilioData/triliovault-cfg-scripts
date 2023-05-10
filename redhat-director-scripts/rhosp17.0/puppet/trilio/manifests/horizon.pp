class trilio::horizon (
    $horizon_dir                        = '/etc/openstack-dashboard',
    $barbican_api_enabled               = hiera('barbican_api_enabled', false),
){

  tag 'triliohorizonconfig'

   if $barbican_api_enabled {
       file_line { "ENABLE OPENSTACK_ENCRYPTION_SUPPORT":
           ensure  => present,
           path   => "${horizon_dir}/local_settings",
           line   => 'OPENSTACK_ENCRYPTION_SUPPORT = True',
           match  => '^OPENSTACK_ENCRYPTION_SUPPORT',
       }
   }
   else {
       file_line { "DISABLE OPENSTACK_ENCRYPTION_SUPPORT":
           ensure  => present,
           path   => "${horizon_dir}/local_settings",
           line   => 'OPENSTACK_ENCRYPTION_SUPPORT = False',
           match  => '^OPENSTACK_ENCRYPTION_SUPPORT',
       }
   }


    file_line { "ENABLE TRILIO_ENCRYPTION_SUPPORT":
        ensure => present,
        path   => "${horizon_dir}/local_settings",
        line   => 'TRILIO_ENCRYPTION_SUPPORT = True',
        match  => '^TRILIO_ENCRYPTION_SUPPORT',
    }
}
