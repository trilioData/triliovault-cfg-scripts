# == Class: trilio::tripleo::mysql
#
# MySQL profile for tripleo
#
# === Parameters
#
# [*bootstrap_node*]
#   (Optional) The hostname of the node responsible for bootstrapping tasks
#   Defaults to hiera('mysql_short_bootstrap_node_name')
# [*step*]
#   (Optional) The current step in deployment. See tripleo-heat-templates
#   for more details.
#   Defaults to hiera('step')
#
#
class trilio::tripleo::mysql (
  $bootstrap_node                = hiera('mysql_short_bootstrap_node_name', undef)
  $step                          = Integer(hiera('step')),
) {

  if $::hostname == downcase($bootstrap_node) {
    $create_db = true
  } else {
    $create_db = false
  }

  if $step >= 2 and $create_db {
    if hiera('trilio_datamover_api_enabled', false) {
      ::tripleo::profile::base::database::mysql::include_and_check_auth{'::trilio::db::mysql':}
    }    
  }
}