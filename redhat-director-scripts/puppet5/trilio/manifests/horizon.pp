class trilio::horizon (
    $horizon_dir                        = '/usr/share/openstack-dashboard/',
){


    file_line { 'trilio_enable_custom_module':
        path => '/etc/openstack-dashboard/local_settings',
        line => "HORIZON_CONFIG['customization_module'] = 'dashboards.overrides'",
    }


}
