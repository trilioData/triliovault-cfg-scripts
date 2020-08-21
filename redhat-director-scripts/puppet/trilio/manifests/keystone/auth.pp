class trilio::keystone::auth (
  $password,
  $auth_name              = 'trilio',
  $tenant                 = 'services',
  $email                  = 'trilio@localhost',
  $public_url             = 'http://127.0.0.1:8784/v2',
  $internal_url           = 'http://127.0.0.1:8784/v2',
  $admin_url              = 'http://127.0.0.1:8784/v2',
  $configure_endpoint     = true,
  $configure_user         = true,
  $configure_user_role    = true,
  $service_name           = 'dmapi',
  $service_type           = 'datamover',
  $service_description    = 'Trilio Datamover Service',
  $region                 = 'RegionOne',
) {

  if $configure_endpoint {
    Keystone_endpoint["${region}/${service_name}::${service_type}"] -> Anchor['trilio::service::end']
  }

  keystone::resource::service_identity { 'dmapi':
    configure_user      => $configure_user,
    configure_user_role => $configure_user_role,
    configure_endpoint  => $configure_endpoint,
    service_type        => $service_type,
    service_description => $service_description,
    service_name        => $service_name,
    region              => $region,
    auth_name           => $auth_name,
    password            => $password,
    email               => $email,
    tenant              => $tenant,
    public_url          => $public_url,
    admin_url           => $admin_url,
    internal_url        => $internal_url,
  }

  if $configure_user_role {
    Keystone_user_role["${auth_name}@${tenant}"] -> Anchor['cinder::service::end']
  }

}