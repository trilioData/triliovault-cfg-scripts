# == Class: trilio::keystone::auth
#
# Configures trilio user, service and endpoint in Keystone.
#
# === Parameters
#
# [*password*]
#   Password for trilio user. Required.
#
# [*email*]
#   Email for trilio user. Optional. Defaults to 'trilio@localhost'.
#
#
# [*auth_name*]
#   Username for trilio service. Optional. Defaults to 'trilio'.
#
#
# [*configure_endpoint*]
#   Should trilio endpoint be configured? Optional. Defaults to 'true'.
#   API v1 endpoint should be enabled in Icehouse for compatibility with Nova.
#
#
# [*configure_user*]
#   Should the service user be configured? Optional. Defaults to 'true'.
#
#
# [*configure_user_role*]
#   Should the admin role be configured for the service user?
#   Optional. Defaults to 'true'.
#
#
# [*service_name*]
#   (optional) Name of the service.
#   Defaults to 'trilio'.
#
#
# [*service_type*]
#    Type of service. Optional. Defaults to 'volume'.
#
#
# [*service_description*]
#    (optional) Description for keystone service.
#    Defaults to 'trilio Service'.
#
#
# [*region*]
#    Region for endpoint. Optional. Defaults to 'RegionOne'.
#
# [*tenant*]
#    Tenant for trilio user. Optional. Defaults to 'services'.
#
# [*public_url*]
#   (optional) The endpoint's public url. (Defaults to 'http://127.0.0.1:8784/v2')
#   This url should *not* contain any trailing '/'.
#
# [*internal_url*]
#   (optional) The endpoint's internal url. (Defaults to 'http://127.0.0.1:8784/v2')
#   This url should *not* contain any trailing '/'.
#
# [*admin_url*]
#   (optional) The endpoint's admin url. (Defaults to 'http://127.0.0.1:8784/v2')
#   This url should *not* contain any trailing '/'.
#

#
# === Examples
#
#  class { 'trilio::keystone::auth':
#    public_url   => 'https://10.0.0.10:8784/v2',
#    internal_url => 'https://10.0.0.20:8784/v2',
#    admin_url    => 'https://10.0.0.30:8784/v2',
#  }
#


class trilio::keystone::auth (
  $password,
  $auth_name              = 'dmapi',
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

}