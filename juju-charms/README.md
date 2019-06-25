# Overview

Provides 3 TrilioVault charms

            charm-trilio-data-mover-api
            charm-trilio-data-mover
            charm-trilio-horizon-plugin

trilio_test_bundle.yaml - Bundle to deploy Openstack services and TrilioVault 
service with TrilioVault charms

trilio_overlay_bundle.yaml - Overlay bundle to deploy TrilioVault service with TrilioVault charms on an existing Openstack

# Usage

TrilioVault Data Mover API is a principal charm and provides API service for TrilioVault Datamover

TrilioVault Data Mover is a sub-ordinate charm of nova-compute

TrilioVault Horizon Plugin is a sub-ordinate charm of openstack-dashboard

Steps to deploy the charm:

1. TrilioVault appliance should be up and running before deploying the bundle.

2. Edit the bundle trilio_test_bundle.yaml or trilio_overlay_bundle.yaml to provide config options as below:

    For trilio-horizon-plugin:
  
        python-version: "Openstack base python version(2 or 3)"
        NOTE - Default value is set to "3". Please ensure to update this based on python version since installing
               python3 packages on python2 based setup might have unexpected impact.

    For trilio-dm-api:
  
        openstack-origin: "Repository from which to install"
        python-version: "Openstack base python version(2 or 3)"
        NOTE - Default value is set to "3". Please ensure to update this based on python version since installing
               python3 packages on python2 based setup might have unexpected impact.
    
    For trilio-data-mover:
  
        python-version: "Openstack base python version(2 or 3)"
        NOTE - Default value is set to "3". Please ensure to update this based on python version since installing
               python3 packages on python2 based setup might have unexpected impact.

        backup-target-type: "Backup target type e.g. nfs or s3"

        For NFS backup target:

                 nfs-shares: "NFS Shares IP address only for nfs backup target"

        For Amazon S3 bakup target:

                 tv-s3-secret-key: "S3 secret access key"

                 tv-s3-access-key: "S3 access key"

                 tv-s3-region-name: "S3 region name"

                 tv-s3-bucket: "S3 bucket name"

        For non-AWS S3 bakup target:

                 tv-s3-secret-key: "S3 secret access key"

                 tv-s3-access-key: "S3 access key"
                 
                 tv-s3-endpoint-url: S3 endpoint URL

                 tv-s3-region-name: "S3 region name"

                 tv-s3-bucket: "S3 bucket name"


      TrilioVault Packages are downloaded from the repository added in below config parameter. Please change this only if you wish to download
      TrilioVault Packages from a different source. This option is same for all 3 charms.
         triliovault-pkg-source: Repository address of triliovault packages

      The configuration options need to be updated based on the S3 specific requirements and the parameters that are not needed can be omitted.


3. deploy the bundle:

        juju deploy trilio_test_bundle.yaml
        
        OR
        
        juju deploy <Openstack base bundle> --overlay trilio_overlay_bundle.yaml

# Contact Information

Trilio Support <support@trilio.com>
