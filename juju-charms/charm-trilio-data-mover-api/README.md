# Overview

TrilioVault Data Mover API provides API service for TrilioVault Datamover

# Usage

TrilioVault Data Mover API relies on services from mysql, rabbitmq-server
and keystone charms. Steps to deploy the charm:

juju deploy trilio-dm-api --config "triliovault-ip=1.2.3.4"

juju deploy keystone

juju deploy mysql

juju deploy rabbitmq-server

juju add-relation trilio-dm-api rabbitmq-server

juju add-relation trilio-dm-api mysql

juju add-relation trilio-dm-api keystone

# Configuration

triliovault-ip - IP Address of the TrilioVault Appliance

TrilioVault appliance should be up and running before deploying this charm.

# Contact Information

Trilio Support <support@trilio.com>
