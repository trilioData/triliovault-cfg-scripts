# Overview

TrilioVault Horizon Plugin is a plugin of TrilioVault which is installed
on the Openstack and provides TrilioVault UI components.

# Usage

TrilioVault Horizon Plugin is a sub-ordinate charm of openstack-dashboard
and relies on services from openstack-dashboard.

Steps to deploy the charm:

juju deploy trilio-horizon-plugin

juju deploy openstack-dashboard

juju add-relation trilio-horizon-plugin openstack-dashboard

# Configuration

python-version: "Openstack base python version(2 or 3)"

NOTE - Default value is set to "3". Please ensure to update this based on python version since installing
       python3 packages on python2 based setup might have unexpected impact.

TrilioVault Packages are downloaded from the repository added in below config parameter. Please change this only if you wish to download
TrilioVault Packages from a different source.

triliovault-pkg-source: Repository address of triliovault packages

# Contact Information

Trilio Support <support@trilio.com>

## Build and publish

This charm is built and published to Charmhub as `trilio-charmers-trilio-horizon-plugin` by the `juju-charms-build-publish.yml` GitHub Actions workflow. A merge that changes this directory on the release branch builds only this charm and releases it to the channel in the `CHARMHUB_DEFAULT_CHANNEL` repository variable. To rebuild it without a code change, change the UUID in the `rebuild` file.
