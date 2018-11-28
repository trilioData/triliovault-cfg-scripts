# Overview

TrilioVault Configurator configures TrilioVault appliance.

# Usage

TrilioVault Configurator relies on services from trilio-datamover-api.
Steps to deploy the charm:

juju deploy trilio-configurator --config user-config.yaml

juju deploy trilio-dm-api --config "triliovault-ip=1.2.3.4"

juju add-relation trilio-configurator trilio-dm-api

# Configuration

Please provide below configuration options using a config file:

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


TrilioVault appliance should be up and running before deploying this charm.

The configuration options need to be updated based on the S3 specific requirements and the parameters that are not needed can be omitted.

# Contact Information

Trilio Support <support@trilio.com>
