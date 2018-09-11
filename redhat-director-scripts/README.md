### 1.Plan for deployment
  #### i) Identify target protocol to store backup images taken by TrilioVault and details needed for configuration: 
     a) NFS - Export IP and path
     b) S3 - Access Key, Secret Key, Region (AWS), Endpoint URL (CEPH), Bucket name
                      
  #### ii) ​TrilioVault supports one node cluster or 3 node HA cluster(TrilioVault in cluster, this is not related to OpenStack HA). Decide which way you
  want to deploy TrilioVault 
  - For 1 node deployment also TrilioVault will enable HA so you need two IP addresses.
  One is fixed ip and one is virtual IP for TrilioVault VM                 .
  - If you select 3 node HA deployment, you will need 4 IP addresses. 3 IP addresses   
   for 3 tvm (TrilioVault VM )nodes, 1 for virtual IP
### 2. Launch TrilioVault VM(s) on a KVM server
Refer: TrilioVault Deployment Guide

### 3. If overcloud is getting deployed for the first time (Not deployed yet):
If overcloud is not deployed already, in that case user should install trilio rpms on overcloud image before starting deployment.
Trilio RPM packages are provided through yum repo hosted on triliovault VM launched during step2.

#### i) Inject Trilio yum repository and install Trilio puppet rpm on overcloud image. [Refer: https://access.redhat.com/documentation/en-us/red_hat_openstack_platform/10/html/partner_integration/overcloud_images]
Command to install repo on overcloud:
```
##Replace TrilioVault_VM_IP with actual triliovault vm IP launched in step2
$ cat trilio.repo
[trilio]
name=Trilio Repository
baseurl=http://<TrilioVault_VM_IP>:8085/yum-repo/queens/
enabled=1
gpgcheck=0

$ virt-customize --selinux-relabel -a overcloud-full.qcow2 --upload trilio.repo:/etc/yum.repos.d/
[  0.0] Examining the guest ...
[ 12.0] Setting a random seed
[ 12.0] Copying: opendaylight.repo to /etc/yum.repos.d/
[ 13.0] Finishing off

##Install trilio puppet module on overcloud image 
virt-customize --selinux-relabel -a overcloud-full.qcow2 --install puppet-triliovault
 ```
 
skip step 4 and jump to step5. Step4 is required in case of already deployed overcloud.
### 4. If overcloud is already deployed:
Following commands used to upload trilio puppet module to overcloud. Module will actually get upload on overcloud during next deployment.
```
##Run following commands on undercloud node
cd /home/stack
git clone https://github.com/trilioData/triliovault-cfg-scripts.git
cd triliovault-cfg-scripts/redhat-director-scripts/
# ./upload_puppet_module.sh
Creating tarball...
Tarball created.
Creating heat environment file: /root/.tripleo/environments/puppet-modules-url.yaml
Uploading file to swift: /tmp/puppet-modules-8Qjya2X/puppet-modules.tar.gz
+-----------------------+---------------------+----------------------------------+
| object                | container           | etag                             |
+-----------------------+---------------------+----------------------------------+
| puppet-modules.tar.gz | overcloud-artifacts | 368951f6a4d39cfe53b5781797b133ad |
+-----------------------+---------------------+----------------------------------+
Upload complete.
```

### 5. Update overcloud roles data file to include trilio services: [On undercloud node]
This python file script will append trilio services to compute and controller role in roles data file.
It will not edit original roles_data file, rather it will create a new  roles_data.yaml file in current directory.
```
#/usr/bin/python prepare_roles_data.py /usr/share/openstack-tripleo-heat-templates/roles_data.yaml
```
New roles data file is created at: /root/git/triliovault-cfg-scripts/redhat-director-scripts/roles_data.yaml
To install trilio components on overcloud, you need to use this new roles data file


### 6. Prepare Trilio container images
#### i) Trilio containers are pushed to dockerhub for now. In future we will be committing them to Redhat registry. Container names are as follows:
TrilioVault Datamove container: https://hub.docker.com/r/trilio/trilio-datamover/
TrilioVault Datamover Api Container: https://hub.docker.com/r/trilio/trilio-datamover-api/
OpenStack horizon with TrilioVault horizon plugin: https://hub.docker.com/r/trilio/openstack-horizon-with-trilio-plugin/

Code repositories are publicly available on github here: https://github.com/trilioData/triliovault-cfg-scripts/tree/master/redhat-director-scripts

Note: Use 'queens' tagged containers.
 Following script downloads trilio images from docker hub and uploads them to undercloud's local container registry. You need to provide undercloud ip as argument to script. Script assumes your undercloud container registry is running on 8787 port. If not you need to directly change it in script.
 ```
./prepare_trilio_images.sh <undercloud_ip> <container_tag>
./prepare_trilio_images.sh 192.168.13.34 queens
```
### 7. Update horizon container name in overcloud_images.yaml
Trilio has created a new horizon container from rhosp13/openstack-horizon container as base image.
Here is it's code: https://github.com/trilioData/triliovault-cfg-scripts/tree/master/redhat-director-scripts/docker/trilio-horizon-plugin​
This container will have rhosp13 openstack horizon + TrilioVault's horizon plugin. User needs to replace openstack horizon container name by this new name in overcloud_images.yaml file.
Name of container: <undercloud_ip>:8787/$/trilio/openstack-horizon-with-trilio-plugin:queens
in overcloud_images.yaml  entry looks like following. Edit IP with your undercloud IP if you are using local registry.
```
DockerHorizonImage: 192.168.122.151:8787/trilio/openstack-horizon-with-trilio-plugin:ditest
```
### 8. Provide environment details in trilio-env.yaml
Provide backup target details and other necessary details in environment file.
This environment file will be used in overcloud deployment to configure trilio components. Container image names are already populated correctly by step6. So, you don't need to edit those now. Just make sure image locations provided here are correct. Environment file is self explainatory. 
```
##Don't need to edit resource registry section 
resource_registry:
  OS::TripleO::Services::TrilioDatamover: docker/services/trilio-datamover.yaml 
  OS::TripleO::Services::TrilioDatamoverApi: docker/services/trilio-datamover-api.yaml

parameter_defaults:

   ##Define network map for trilio datamover api service
   ServiceNetMap:
       TrilioDatamoverApiNetwork: internal_api

   ##Container locations
   DockerTrilioDatamoverImage: 192.168.122.10:8787/trilio/trilio-datamover:3.1.31

   DockerTrilioDmApiImage: 192.168.122.10:8787/trilio/trilio-datamover-api:3.1.31

   ##Datamover api port, default is 8784
   DmApiPort: 8784

  ##If user wants to enable SSL for datamover api's public endpoint in haproxy
  ##Default value is 'true'
   DmApiEnableSSL: true

  ## If you are enabling ssl for datamover api public endpoint then following parameter is 
  ## taken into consideration otherwise not
   DmApiSslPort: 13784

   ## Following parameter expects datamover api public endpoint url in keystone catalog
   ## This endpoint url is created during triliovault configuration step
   DmApiLinkPrefix: http://192.168.122.25:8784

   ##Backup target nfs/s3
   BackupTargetType: 'nfs'

   ##For backup target 'nfs'
   NfsShares: '192.168.122.101:/opt/tvault'
   NfsOptions: 'nolock,soft,timeo=180,intr,lookupcache=none'

   ## For backup target 's3'
   ## S3 type: amazon_s3/ceph_s3
   S3Type: 'amazon_s3'

   ## S3 access key
   S3AccessKey: ''
  
   ## S3 secret key
   S3SecretKey: ''

   ## S3 region, if your s3 does not have any region, just keep the parameter as it is
   S3RegionName: ''

   ## S3 bucket name
   S3Bucket: ''

   ## S3 endpoint url, not required for Amazon S3, keep it as it is
   S3EndpointUrl: ''

   ## If SSL enabled on S3 url, not required for Amazon S3, just keep it as it is
   S3SslEnabled: false

   ##Don't edit following parameter
   EnablePackageInstall: True
 ```

### 9. Deploy overcloud with trilio environment  and new roles data file
Use following heat environment files and roles data file in overcloud deploy command
1. trilio_env.yaml  : This environment file contains trilio backup target details and trilio container image locations
2. roles_data.yaml : This file contains overcloud roles data with trilio roles added.
3. overcloud_images.yaml: This file holds container locations for all overcloud containers.

To include new environment files use '-e' option and for roles data file use '-r' option.
Sample overcloud deployment command with trilio looks like following
```
openstack overcloud deploy --templates \
-e /home/stack/overcloud_images.yaml
-e ${basedir}/trilio_env.yaml \
-r ${basedir}/roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org \
```
Trilio will install it's following components
i)   TrilioVault datamover container on all compute nodes
ii)  TrilioVault datamover api container on all controller nodes
iii) TrilioVault horizon plugin in all OpenStack Horizon containers
10. Steps to verify correct deployment:
#### a) On controller node: 
Make sure trilio dmapi and horizon containers(shown below) are in running state and no other trilio container is deployed on controller nodes. If the containers are in restarting state or not listed by following command then your deployment is not done correctly. You need to revisit above steps.
```
[root@overcloud-controller-0 trilio]# docker container ls | grep trilio
cad4b68a6436        192.168.122.151:8787/trilio/trilio-datamover-api:ditest                    "kolla_start"            2 days ago          Up 2 days                                 trilio_dmapi
10b95b501092        192.168.122.151:8787/trilio/openstack-horizon-with-trilio-plugin:ditest    "kolla_start"            2 days ago          Up 2 days                                 horizon
 ```
#### b) On compute node
Make sure trilio datamover container (shown below) is in running state and no other trilio container is deployed on compute nodes. If the containers are in restarting state or not listed by following command then your deployment is not done correctly. You need to revisit above steps. 
```
#docker container ls | grep trilio

2598963695c7        192.168.122.151:8787/trilio/trilio-datamover:ditest                        "kolla_start"       2 days ago          Up 2 days                                 trilio_datamover
```
#### c) On Overcloud's horizon dashboard:
Once you login to dashboard, you should see a new tab in project space named "Backups"  and one more tab in admin space named "Backups-Admin".
These two tabs belongs to triliovault. If you see these two tabs on openstack dashboard of overcloud then triliovault's horizon plugin is deployed correctly.

### 11. Configure TrilioVault cluster
If overcloud is deployed, then you can configure triliovault otherwise you can do it later also(After deploying overcloud).
Refer: TrilioVault Deployment Guide

### 12. To verify end-to-end integration:
i) Login to openstack dashboard
ii) Navigate to "Backups" tab and create a workload
iii) Take a snapshot of workload, it should complete successfully
iv) Restore the snapshot using 'selective restore' type, it should correctly restore the vms and it's configuration on openstack cloud.
If snapshot and restore works fine, it means your deployment is working end to end.
13. Troubleshooting if any failures:
Trilio components will be deployed in step5 of overcloud deployment using puppet scripts.
If overcloud deployment fails you can list failures first using following command.
openstack stack failures list overcloud
```
heat stack-list --show-nested -f "status=FAILED"
heat resource-list --nested-depth 5 overcloud | grep FAILED
-r ${basedir}/roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log
```
