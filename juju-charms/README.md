# Overview

Provides 3 TrilioVault charms

            charm-trilio-data-mover-api
            charm-trilio-data-mover
            charm-trilio-horizon-plugin

trilio_test_bundle.yaml - Bundle to deploy Openstack services and TrilioVault 
service with TrilioVault charms

# Usage

TrilioVault Data Mover API is a principal charm and provides API service for TrilioVault Datamover

TrilioVault Data Mover is a sub-ordinate charm of nova-compute

TrilioVault Horizon Plugin is a sub-ordinate charm of openstack-dashboard


Steps to deploy the charm:

1. TrilioVault appliance should be up and running before deploying the bundle.

2. Edit the bundle trilio_test_bundle.yaml to provide config options as below:

    For trilio-horizon-plugin:
  
        triliovault-ip: "IP Address of  TrilioVault Appliance"

    For trilio-dm-api:
  
        triliovault-ip: "IP Address of  TrilioVault Appliance"
    
    For trilio-data-mover:
  
        triliovault-ip: "IP Address of the TrilioVault Appliance"

        backup-target-type: "Backup target type e.g. nfs or s3"

        For NFS backup target:

                 nfs-shares: "NFS Shares IP address only for nfs backup target"

        For S3 bakup target:

                 tv-s3-secret-key: "S3 secret access key"

                 tv-s3-access-key: "S3 access key"

                 tv-s3-region-name: "S3 region name"

                 tv-s3-bucket: "S3 bucket name"

3. deploy the bundle:

        juju deploy trilio_test_bundle.yaml

# Contact Information

Trilio Support <support@trilio.com>
