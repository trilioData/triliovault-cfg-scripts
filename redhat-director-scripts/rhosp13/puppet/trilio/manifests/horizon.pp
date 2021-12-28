class trilio::horizon (
    $horizon_dir                        = '/etc/openstack-dashboard',
){

  tag 'triliohorizonconfig'

   if $barbican_api_enabled == 'true' {
       file_line { "Set $line in ${horizon_dir}/local_settings":  
           ensure  => present,
           path   => "${horizon_dir}/local_settings",
	   line   => 'OPENSTACK_ENCRYPTION_SUPPORT = True',
	   match  => '^OPENSTACK_ENCRYPTION_SUPPORT',
        }
   }    
   else {
       file_line { "Set $line in ${horizon_dir}/local_settings":  
           ensure  => present,
           path   => "${horizon_dir}/local_settings",
	   line   => 'OPENSTACK_ENCRYPTION_SUPPORT = False',
	   match  => '^OPENSTACK_ENCRYPTION_SUPPORT',
        }
   }
 

    file_line { "Set $line in ${horizon_dir}/local_settings":
        ensure => present,
        path   => "${horizon_dir}/local_settings",
        line   => 'TRILIO_ENCRYPTION_SUPPORT = False',
        match  => '^TRILIO_ENCRYPTION_SUPPORT',
    }

}
