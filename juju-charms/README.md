# Overview

Provides 4 TrilioVault charms

            charm-trilio-data-mover-api
            charm-trilio-data-mover
            charm-trilio-horizon-plugin
            charm-trilio-configurator

trilio_test_bundle.yaml - Bundle to deploy Openstack services and TrilioVault 
service with TrilioVault charms

trilio_overlay_bundle.yaml - Overlay bundle to deploy TrilioVault service with TrilioVault charms on an existing Openstack

# Usage

TrilioVault Data Mover API is a principal charm and provides API service for TrilioVault Datamover

TrilioVault Data Mover is a sub-ordinate charm of nova-compute

TrilioVault Horizon Plugin is a sub-ordinate charm of openstack-dashboard

TrilioVault Configurator is a sub-ordinate charm of TrilioVault Data Mover API charm.

Steps to deploy the charm:

1. TrilioVault appliance should be up and running before deploying the bundle.

2. Edit the bundle trilio_test_bundle.yaml or trilio_overlay_bundle.yaml to provide config options as below:

    For trilio-horizon-plugin:
  
        triliovault-ip: "IP Address of  TrilioVault Appliance"

    For trilio-dm-api:
  
        triliovault-ip: "IP Address of  TrilioVault Appliance"
    
    For trilio-data-mover:
  
        triliovault-ip: "IP Address of the TrilioVault Appliance"

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


      TrilioVault appliance should be up and running before deploying this charm.

      The configuration options need to be updated based on the S3 specific requirements and the parameters that are not needed can be omitted.


3. deploy the bundle:

        juju deploy trilio_test_bundle.yaml
        
        OR
        
        juju deploy <Openstack base bundle> --overlay trilio_overlay_bundle.yaml

4. After deploying trilio-horizon-plugin, trilio-dm-api and trilio-data-mover, trilio-configurator charm can be used to configure TrilioValt appliance. 

Steps to deploy the charm:

            juju deploy trilio-configurator --config user-config.yaml
            juju deploy trilio-dm-api --config "triliovault-ip=1.2.3.4"
            juju add-relation trilio-configurator trilio-dm-api

Configuration - Please provide below configuration options using a config file <<user-config.yaml>>:

      # TrilioVault config details
      tv-conf-node-ip: *triliovault-ip                  <<IP Address of the TrilioVault Appliance>>
      tv-conf-user: "admin"                             <<Username for TrilioVault Appliance>>
      tv-conf-pass: "password"                          <<Password for TrilioVault Appliance>>
      tv-controller-nodes: "192.168.25.16=jujuTVM62"    <<TrilioVault IP=Node name combination for TrilioVault Appliance>>
      tv-virtual-ip: "192.168.25.17/24"                 <<Virtual IP Address of the TrilioVault Appliance>>
      tv-name-server: "8.8.8.8"                         <<Name server>>
      tv-dom-search-order: "triliodata.demo"            <<Domain search order>>
      tv-timezone: "Etc/UTC"                            <<Timezone>>
      
      # Openstack config details
      tv-keystone-admin-url: "http://172.172.0.18:35357/v3" <<Keystone Admin endpoint URL>>
      tv-keystone-public-url: "http://172.172.0.18:5000/v3" <<Keystone Public endpoint URL>>
      tv-dm-endpoint: "http://172.172.0.20:8784"            <<Datamover API endpoint URL>>
      tv-os-username: "admin"                               <<Openstack username>>
      tv-os-password: "openstack"                           <<Openstack password>>
      tv-os-tenant-name: "admin"                            <<Openstack tenant/project name>>
      tv-os-region-name: "RegionOne"                        <<Openstack region name>>
      tv-os-domain-id: "0e016f5a699b4eada6d5e7f999b569cb"   <<Openstack domain ID>>
      tv-os-trustee-role: "Admin"                           <<Openstack trustee role>>
      
      # Backup details
      tv-backup-target-type: Backup target type e.g. nfs or s3
      
      For NFS backup target:
        nfs-shares: NFS Shares IP address only for nfs backup target
      
      OR
      
      For Amazon S3 backup target:
      tv-s3-type: Amazon
      tv-s3-access-key: S3 access key
      tv-s3-secret-key: S3 secret key
      tv-s3-bucket: Bucket name
      tv-s3-region-name: Region Name
      
      OR
      
      For non-AWS S3 backup target:
      tv-s3-type: Ceph
      tv-s3-access-key: S3 access key
      tv-s3-secret-key: S3 secret key
      tv-s3-bucket: Bucket name
      tv-s3-endpoint-url: S3 endpoint URL
      tv-s3-region-name: Region Name
      
      tv-import-workloads: True or False    <<Enable Import Workloads or not>>

# Contact Information

Trilio Support <support@trilio.com>
