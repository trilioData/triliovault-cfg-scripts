# == Class: trilio::tripleo::mysql
#
# MySQL profile for tripleo
#
# === Parameters
#
# [*bootstrap_node*]
#   (Optional) The hostname of the node responsible for bootstrapping tasks
#   Defaults to hiera('mysql_short_bootstrap_node_name')

class trilio::tripleo::mysql (
  $bootstrap_node                = hiera('mysql_short_bootstrap_node_name', undef),
) {

  if $::hostname == downcase($bootstrap_node) {
    $create_db = true
  } else {
    $create_db = false
  }

  if $create_db {
    if hiera('trilio_datamover_api_enabled', false) {
      include ::trilio::db::mysql
    }    
  }
}