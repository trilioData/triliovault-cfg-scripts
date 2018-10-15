# Overview

TrilioVault Data Mover provides service for TrilioVault Datamover
on each compute node.

# Usage

TrilioVault Data Mover relies on services from nova-compute and rabbitmq-server.
Steps to deploy the charm:

juju deploy trilio-data-mover --config user-config.yaml

juju deploy nova-compute

juju deploy rabbitmq-server

juju add-relation trilio-data-mover rabbitmq-server

juju add-relation trilio-data-mover nova-compute

# Configuration

Please provide below configuration options using a config file:

triliovault-ip: IP Address of the TrilioVault Appliance

tvault-datamover-ext-usr: User name e.g. "nova"

tvault-datamover-ext-group: Group name e.g. "nova"

tvault-datamover-virtenv: Virtual env e.g. /home/tvault/.virtenv

tvault-datamover-virtenv-path: Virtual env path e.g. /home/tvault

tv-datamover-conf: Config file e.g. /etc/tvault-contego/tvault-contego.conf

backup-target-type: Backup target type e.g. nfs or s3

nfs-shares: NFS Shares mount source path only for nfs backup target

tv-data-dir: TrilioVault data dir e.g. /var/triliovault-mounts

tv-data-dir-old: Old TrilioVault data dir e.g. /var/triliovault

tv-s3-secret-key: S3 secret access key

tv-s3-access-key: S3 access key

tv-s3-type: S3 type e.g. Amazon

tv-s3-region-name: S3 region name

tv-s3-bucket: S3 bucket name

tv-s3-endpoint-url: S3endpoint URL

tv-s3-secure: true or false

TrilioVault appliance should be up and running before deploying this charm.

# Contact Information

Trilio Support <support@trilio.com>
