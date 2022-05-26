Install 'triliovault' helm chart



Note: Run following steps on node from where you have install openstack cloud helm charts.

1. Pre-requisites

1.1] Install Helm CLI client

if helm CLI client is not installed on server from where you want to install triliovault, you need to install it.

This is needed only on single server which you are planning to as installation node.

wget https://get.helm.sh/helm-v3.7.2-linux-amd64.tar.gz

tar -zxvf helm*.tar.gz 

mv linux-amd64/helm /usr/local/bin/helm

rm -rf linux-amd64 helm*.tar.gz




1.2] Install nfs-common package

If you are planning to use ‘nfs’ as backup target for triliovault backups, then only you need to perform this step. In case of S3 backup target, you can skip this step.

## SSH to every kubernetes node (triliovault-control-plane=enabled, openstack-compute-node=enabled)
## And install nfs-common package using following command.
apt-get install nfs-common -y



1.3] Install necessary dependent packages

sudo apt update -y && apt install make jq -y

2. Clone triliovault helm chart code repository  

git clone https://github.com/trilioData/triliovault-cfg-scripts.git
cd triliovault-cfg-scripts/
git checkout beta/5.0
cd openstack-helm/triliovault/
helm dep up
cd ../../../

3. Set container image tags 

If your openstack cloud is train ubuntu bionic, set your image tags in following file.

Edit triliovault image tags only.

vi triliovault-cfg-scripts/openstack-helm/triliovault/values_overrides/victoria-ubuntu_focal.yaml



4. Create 'triliovault' namespace to run triliovault services.

kubectl create namespace triliovault
kubectl config set-context --current --namespace=triliovault



5. Set correct labels to Kubernetes nodes.

TrilioVault control plane service will be deployed on kubernetes nodes having label 'triliovault-control-plane=enabled' .

It is recommended to use three kubernetes nodes for control plane.

Please use following commands

Get openstack control plane node names

kubectl get nodes --show-labels | grep openstack-control-plane

Assign ‘triliovault-control-plane' label to these nodes. OR you can choose another set of nodes for 'triliovault-control-plane’.

kubectl label nodes <MOSK_NODE_NAME1> triliovault-control-plane=enabled
kubectl label nodes <MOSK_NODE_NAME2> triliovault-control-plane=enabled
kubectl label nodes <MOSK_NODE_NAME3> triliovault-control-plane=enabled

Verify list of nodes having 'triliovault-control-plane' label

kubectl get nodes --show-labels | grep triliovault-control-plane



6. Edit following yaml file and provide triliovault backup target details and other necessary details.



vi triliovault-cfg-scripts/openstack-helm/triliovault/values_overrides/conf_triliovault.yaml



If the backup target for triliovault is of ‘S3' type with self signed certificates, then user needs to store S3’s ca certificate in following file.

triliovault/files/s3-cert.pem

Devops code will copy this file at appropriate location during triliovault helm chart installation.



6. Fetch keystone, database and rabbitmq credentials and create a yaml file.

6.1] Get internal_domain_name and public_domain_name from your mosk ospdl template or you can get it from openstack endpoint list command.

i. First approach

Get into the keystone client container using below command from the host:

kubectl -n openstack exec $(kubectl -n openstack get pod -l application=keystone,component=client -ojsonpath='{.items[*].metadata.name}') -ti -- bash

Once You are in the container 

kubectl -n openstack exec $(kubectl -n openstack get pod -l application=keystone,component=client -ojsonpath='{.items[*].metadata.name}') -ti -- bash

heat@keystone-client-55d7f79684-5v8hd:/$ openstack endpoint list | grep glance
| 5bdd6c890b6842bda7b5d9d6d5480ab0 | RegionOne | glance       | image          | True    | admin     | http://glance-api.openstack.svc.cluster.local:9292                  |
| 85b7eb9a7e0a43abb7a25daf4244c480 | RegionOne | glance       | image          | True    | public    | https://glance.triliodata.demo                                      |
| 9b9fc51521424aa1839ba6101180ea82 | RegionOne | glance       | image          | True    | internal  | http://glance-api.openstack.svc.cluster.local:9292  

From above output, 

internal_domain_name = cluster.local

public_domain_name = triliodata.demo

OR
ii.  Get it from your 'openstackdeployment.yaml'

cd /PATH/TO/YOUR/OPENSTACK_DEPLOYMENT_YAML

root@helm1:~# grep "domain_name" openstackdeployment.yaml
  internal_domain_name: cluster.local
  public_domain_name: triliodata.demo



6.2] Fetch admin credentials:


Edit <internal_domain_name>, <public_domain_name>, set it to values we collected in previous step.

cd triliovault-cfg-scripts/openstack-helm/triliovault/utils
./get_admin_creds.sh <internal_domain_name> <public_domain_name>

For Example:
./get_admin_creds.sh cluster.local triliodata.demo

Output will be written to file 'openstack-helm/triliovault/values_overrides/admin_creds.yaml'

cat ../values_overrides/admin_creds.yaml



7.  Prepare 'ceph.yaml' 

If ceph is used as nova/cinder backend storage in openstack cloud, we need to prepare ceph.yaml for triliovault deployment.

File location:

triliovault-cfg-scripts/openstack-helm/triliovault/values_overrides/ceph.yaml

Edit this file and populate 

Manual Approach.

cd triliovault-cfg-scripts/openstack-helm/triliovault/values_overrides/
## Provide rbd_user, keyring. This user needs to have read,write access on vms, volumes pool used for nova, cinder backend.
## By default 'nova' user generally has these permissions. But we recommend to verify and use it for triliovault.
vi ceph.yaml

## Copy your /etc/ceph/ceph.conf content to following file. Clean existing file content.
vi ../templates/bin/_triliovault-ceph.conf.tpl

Automated approach.-- Automated approach use 'nova' as ceph user for triliovault.

cd triliovault-cfg-scripts/openstack-helm/triliovault/utils
./get_ceph.sh

## Output will be written to file - ../values_overrides/ceph.yaml

8. Create docker registry credentials secret.

Create ImagePullSecret for triliovault images in 'triliovault' namespace. TrilioVault images are stored in dockerhub private registry.Get dockerhub pull credentials from Trilio Sales/Support team.

cd triliovault-cfg-scripts/openstack-helm/triliovault/utils

## Edit <DOCKERHUB_USERNAME> and <DOCKERHUB_PASSWORD> placeholders. Get these details from
## Trilio Sales/Support Team.

vi create_image_pull_secret.sh

## Run the script.
./create_image_pull_secret.sh

## Verify that image pull secret created in 'triliovault' namespace.
kubectl describe secret triliovault-image-registry -n triliovault



9. Install TrilioVault Helm Chart

9.1] Review install script


Open following script, which is responsible to install triliovault helm chart into MOSK cloud and review all values_overrides files that we passed. If any file is not valid for your cloud, you can remove/edit that file.

cd triliovault-cfg-scripts/openstack-helm/triliovault/utils/
vi install.sh

 For example,
If MOSK cloud doesn’t use ceph storage for cinder and nova services then you need to disable the ceph in ceph.yaml file.


If Keystone endpoints doesnot have TLS enabled on public endpoint only, you need remove '--values=./triliovault/values_overrides/tls_public_endpoint.yaml' from install script.



9.2] Uninstall existing triliovault chart

If you have already installed triliovault on your MOSK cloud, please un-install it using following document steps.

Refer document: https://triliodata.atlassian.net/wiki/spaces/TVO/pages/3472293889 

9.3] Run install script.


Once you finalize all values overrides files for your cloud, you can run the installation script.

cd triliovault-cfg-scripts/openstack-helm/triliovault/utils/
./install.sh



9.4] Verify installation.



## Check status of triliovault helm chart release
helm status triliovault

## Check if all pods are in running/Completed state.
kubectl get pods -n triliovault

Sample Output:
----------------------
root@mosk1:~/shyam/openstack-helm/triliovault/utils# kubectl get pods -n triliovault
NAME                                                 READY   STATUS             RESTARTS   AGE
triliovault-datamover-api-5cb7dcdb48-9shfn           1/1     Running            0          12m
triliovault-datamover-api-5cb7dcdb48-rdbmm           1/1     Running            0          12m
triliovault-datamover-api-5cb7dcdb48-z7vhk           1/1     Running            0          12m
triliovault-datamover-db-init-wh2cg                  0/1     Completed          0          28h
triliovault-datamover-db-sync-72p6w                  0/1     Completed          0          28h
triliovault-datamover-ks-endpoints-sw9cq             0/3     Completed          0          28h
triliovault-datamover-ks-service-fjcnd               0/1     Completed          0          28h
triliovault-datamover-ks-user-x6rt8                  0/1     Completed          0          28h
triliovault-datamover-openstack-compute-node-9ksxp   1/1     Running            0          12m
triliovault-datamover-openstack-compute-node-xn2cm   1/1     Running            0          28h
triliovault-wlm-api-74cbb9c78c-574ws                 0/1     Running            7          12m
triliovault-wlm-api-74cbb9c78c-dlzb4                 0/1     Running            7          12m
triliovault-wlm-api-74cbb9c78c-mj6vr                 0/1     Running            7          12m
triliovault-wlm-api-d679fb6f7-7q8n5                  1/1     Running            0          28h
triliovault-wlm-api-d679fb6f7-xmdlk                  1/1     Running            0          28h
triliovault-wlm-cloud-trust-tqjqw                    0/1     Completed          0          28h
triliovault-wlm-cron-757f4b78bb-rbx7z                1/1     Running            0          12m
triliovault-wlm-db-init-ktx5b                        0/1     Completed          0          28h
triliovault-wlm-db-sync-l84rs                        0/1     Completed          0          28h
triliovault-wlm-ks-endpoints-hqkvd                   0/3     Completed          0          28h
triliovault-wlm-ks-service-vc9vb                     0/1     Completed          0          28h
triliovault-wlm-ks-user-jzvl6                        0/1     Completed          0          28h
triliovault-wlm-rabbit-init-8kbf7                    0/1     Completed          0          28h
triliovault-wlm-scheduler-6d6d84ccd6-cs99c           1/1     Running            2          12m
triliovault-wlm-workloads-599fc899-554zv             1/1     Running            0          28h
triliovault-wlm-workloads-599fc899-hgtm8             1/1     Running            0          28h
triliovault-wlm-workloads-7d897778b-24khw            1/1     Running            0          12m
triliovault-wlm-workloads-7d897778b-lzblt            1/1     Running            0          12m
triliovault-wlm-workloads-7d897778b-srd4b            1/1     Running            0          12m


## Check if jobs finished well
kubectl get jobs -n triliovault

Sample Output:
--------------
root@mosk1:~/shyam/openstack-helm/triliovault/utils# kubectl get jobs -n triliovault
NAME                                 COMPLETIONS   DURATION   AGE
triliovault-datamover-db-init        1/1           7s         28h
triliovault-datamover-db-sync        1/1           8s         28h
triliovault-datamover-ks-endpoints   1/1           16s        28h
triliovault-datamover-ks-service     1/1           6s         28h
triliovault-datamover-ks-user        1/1           17s        28h
triliovault-wlm-cloud-trust          1/1           2m49s      28h
triliovault-wlm-db-init              1/1           6s         28h
triliovault-wlm-db-sync              1/1           8s         28h
triliovault-wlm-ks-endpoints         1/1           17s        28h
triliovault-wlm-ks-service           1/1           7s         28h
triliovault-wlm-ks-user              1/1           20s        28h
triliovault-wlm-rabbit-init          1/1           3s         28h

## If you are using NFS backup target, check if nfs pvc got into Bound state
kubectl get pvc -n triliovault

Sample Output:
-------------
root@mosk1:~/shyam/openstack-helm/triliovault/utils# kubectl get pvc -n triliovault
NAME                                                STATUS   VOLUME                                             CAPACITY   ACCESS MODES   STORAGECLASS   AGE
triliovault-nfs-pvc-192-168-1-33-mnt-tvault-42424   Bound    triliovault-nfs-pv-192-168-1-33-mnt-tvault-42424   20Gi       RWX            nfs            9m58s