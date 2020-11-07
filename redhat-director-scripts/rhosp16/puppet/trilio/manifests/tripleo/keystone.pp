# == Class: trilio::tripleo::keystone
#
# Keystone profile for trilio
#
# === Parameters
# [*bootstrap_node*]
#   (Optional) The hostname of the node responsible for bootstrapping tasks
#   Defaults to hiera('keystone_short_bootstrap_node_name')

# [*keystone_resources_managed*]
#   (Optional) Enable the management of Keystone resources with Puppet.
#   Can be disabled if Ansible manages these resources instead of Puppet.
#   The resources are: endpoints, roles, services, projects, users and their
#   assignment.
#   Defaults to hiera('keystone_resources_managed', true)
#
class trilio::tripleo::keystone (
  $bootstrap_node                 = hiera('keystone_short_bootstrap_node_name', undef), 
  $keystone_resources_managed     = hiera('keystone_resources_managed', true),
) {
  if $::hostname == downcase($bootstrap_node) and $keystone_resources_managed {
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