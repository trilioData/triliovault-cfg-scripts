# == Class: trilio::tripleo::::keystone
#
# Keystone profile for tripleo
#
# === Parameters
# [*bootstrap_node*]
#   (Optional) The hostname of the node responsible for bootstrapping tasks
#   Defaults to hiera('keystone_short_bootstrap_node_name')

class trilio::tripleo::keystone (
  $bootstrap_node                 = hiera('keystone_short_bootstrap_node_name', undef),
) {
  if $::hostname == downcase($bootstrap_node) {
    $manage_endpoint = true
  } else {
    $manage_endpoint = false
  }

  if $manage_endpoint {
    if hiera('trilio_datamover_api_enabled', false) {
      include ::trilio::keystone::auth
    }
  }
}