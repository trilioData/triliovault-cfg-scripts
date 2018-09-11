# Overview

TrilioVault Horizon Plugin is a plugin of TrilioVault which is installed
on the Openstack and provides TrilioVault UI components.

# Usage

TrilioVault Horizon Plugin is a sub-ordinate charm of openstack-dashboard
and relies on services from openstack-dashboard.

Steps to deploy the charm:

juju deploy trilio-horizon-plugin --config "triliovault-ip=<IP Address>"

juju deploy openstack-dashboard

juju add-relation trilio-horizon-plugin openstack-dashboard

# Configuration

triliovault-ip - IP Address of the TrilioVault Appliance

TrilioVault appliance should be up and running before deploying this charm.

# Contact Information

Trilio Support <support@trilio.com>
