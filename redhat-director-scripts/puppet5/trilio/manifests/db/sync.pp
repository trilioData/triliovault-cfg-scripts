#
# Class to execute dmapi dbsync
#
# == Parameters
#
# [*extra_params*]
#   (Optional) String of extra command line parameters to append
#   to the dmapi-manage db sync command. These will be inserted
#   in the command line between 'dmapi-manage' and 'db sync'.
#   Defaults to ''
#
class trilio::db::sync(
  $extra_params = '',
) {

  exec { 'dmapi-dbsync':
    command     => "dmapi-dbsync",
    path        => '/usr/bin',
    user        => 'dmapi',
    refreshonly => true,
    try_sleep   => 5,
    tries       => 10,
    logoutput   => on_failure,
    tag         => 'openstack-db',
  }

}