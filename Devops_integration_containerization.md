#### This doc explains steps to integrate installation steps of TrilioVault components into your devops framework.


#### 1. TrilioVault has following three components that needs to be installed on existing OpenStack cloud.
1. TrilioVault Datamover Api
2. TrilioVault Datamover
3. TrilioVault Horizon Plugin


#### 2. We have already completed devops integration with following OpenStack deployment tools/distributions.
1. Redhat Director  - https://github.com/trilioData/triliovault-cfg-scripts/tree/master/redhat-director-scripts
2. Kolla-ansible  - https://github.com/trilioData/triliovault-cfg-scripts/tree/master/kolla-ansible
3. OpenStack ansible - https://github.com/trilioData/triliovault-cfg-scripts/tree/master/ansible
4. TripleO  - https://github.com/trilioData/triliovault-cfg-scripts/tree/master/redhat-director-scripts/tripleo-train
5. Canonical OpenStack - juju charms - https://github.com/trilioData/triliovault-cfg-scripts/tree/master/juju-charms

If you are using a deployment tool/ditribution not mentioned in above list then only you need to use this document to integrate the TrilioVault components into your devops framework.



#### 3. As most of the OpenStack cloud distributions are containerized in their latest releases, following are the high level steps to integrate TrilioVault components into user's existing devops framework like ansible/puppet/chef with containerization.

1. Go through manual install steps for above three triliovault components.

2. Create new three separate container images for three triliovault components using install steps defined in step1.

3. Publish these three container images to a centralized container registry/repository.

4. Write necessary devops code to pull these images and launch them during your cloud update/deploy process.



#### 4. Above steps explained in detail.

4.1 Go through manual install steps for above three triliovault components.

Here are the document links. Please go through each document and understand all steps to install triliovault
components. These steps are using rpm/debian package format.
We maintain rpm/debian package repositories on cloud. Those will be accessible to customers only.
These steps will need to performed during container image creation process.

 - TrilioVault Datamover Api Document: https://github.com/trilioData/triliovault-cfg-scripts/blob/master/Datamover_Api_Install_Guide.md
 - TrilioVault Datamover Document: https://github.com/trilioData/triliovault-cfg-scripts/blob/master/Datamover_Extension_Install_Guide.md
 - TrilioVault Horizon Plugin Document: https://github.com/trilioData/triliovault-cfg-scripts/blob/master/Horizon_Plugin_Install_Guide.md

 4.2 Create new three separate container images for three triliovault components using install steps defined in step1.

Create following three container images:
4.2.1 TrilioVault Datamover Api container image creation
- For 'TrilioVault Datamover Api' image use respective 'nova api' image as base image
- Example Dockerfile: https://github.com/trilioData/triliovault-cfg-scripts/blob/master/kolla-ansible/trilio-datamover-api/Dockerfile_victoria_centos


4.2.2 'TrilioVault Datamover' container image creation
- For 'TrilioVault Datamover' image use respective 'nova-compute' image as base image.
- Example Dockerfile:
https://github.com/trilioData/triliovault-cfg-scripts/blob/master/kolla-ansible/trilio-datamover/Dockerfile_victoria_centos


4.2.3 'TrilioVault Horizon Plugin' container image creation
- For 'TrilioVault Horizon Plugin' image, use respective 'Horizon' image as base image
- Example Dockerfile:
https://github.com/trilioData/triliovault-cfg-scripts/blob/master/kolla-ansible/trilio-horizon-plugin/Dockerfile_victoria_centos

All necessary steps and it's required files are available in above github repository(https://github.com/trilioData/triliovault-cfg-scripts).


4.3 Publish these three container images to a centralized container registry/repository.

You can publish these three triliovault component images to your preffered container registry.
Example registries: dockerhub - docker.io, quay.io, on-premise container registry etc.



4.4 Write necessary devops code to pull these images and launch them during your cloud update/deploy process.

Now, we have three container images created and published. We need to write devops code in our existing devops framework, to launch these three container images.

4.4.1 TrilioVault Datamover Api contianer:


4.4.1.1 This should get installed on control plane nodes.

4.4.1.2 Following directories/volumes needs to get mounted from host to container

    
      - /etc/dmapi/                 [or equivalent directory/volume]
      - /var/log/dmapi/             [or equivalent directory/volume]
      - /etc/pki/tls/certs/httpd    [or equivalent directory/volume]
        If TLS enabled on all endpoints of of datamover api service


4.4.1.3 Creating required keystone resoures
- Create keystone user named 'dmapi', set password
     - Register service in keystone. 
       Service name: 'dmapi', Type: 'datamover', Description: "TrilioVault Datamover Api Service",
       Endpoints: public, internal and admin
     - Assign 'admin' role to 'dmapi' user on project 'service' or 'services'


4.4.1.4 Creating required database resources
- A new database needs to be created named 'dmapi'
- Database user named 'dmapi' needs to be created
- Need to grant permissions to 'dmapi' user on all hosts.

4.4.1.5 Database sync
- Run database sync command

```  
/bin/bash -c /usr/bin/dmapi-dbsync

```

4.4.1.6 Add haproxy entry for triliovault datamover api service
```
## If SSL enabled on public interface of dmapi
listen trilio_datamover_api
  bind <Keystone_virtual_ip>:8784  ssl crt /etc/haproxy/haproxy.pem
  server <controller_hostname_1> <controller_IP1>:8784 check inter 2000 rise 2 fall 5
  server <controller_hostname_2> <controller_IP2>:8784 check inter 2000 rise 2 fall 5
  server <controller_hostname_3> <controller_IP3>:8784 check inter 2000 rise 2 fall 5

## If SSL is not enabled on any interface
listen trilio_datamover_api
  bind <Keystone_virtual_ip>:8784
  server <controller_hostname_1> <controller_IP1>:8784 check inter 2000 rise 2 fall 5
  server <controller_hostname_2> <controller_IP2>:8784 check inter 2000 rise 2 fall 5 
  server <controller_hostname_3> <controller_IP3>:8784 check inter 2000 rise 2 fall 5

``` 
   

  Use following commands for the same.

```
1. Login to mysql cluster from mysql node:
docker exec -it galera-bundle-docker-0 mysql

2. Create 'dmapi' database

MariaDB [(none)]> CREATE DATABASE dmapi;
Query OK, 1 row affected (0.00 sec)

3. Change to mysql database
MariaDB [(none)]> use mysql;
Database changed

4. Create 'dmapi' database user

-- Get password from 'trilio_env.yaml'. conf parameter name: TrilioDatamoverPassword
default password: test1234
For example if you set new password in trilio_env.yaml as 'wsffsaqlfwbgsdd'

MariaDB [(none)]> CREATE USER 'dmapi'@'%' IDENTIFIED BY 'wsffsaqlfwbgsdd';
Query OK, 0 rows affected (0.00 sec)

4.Grant full permissions to 'dmapi' user on 'dmapi' database from all hosts

MariaDB [mysql]> GRANT ALL PRIVILEGES ON dmapi.* TO 'dmapi'@'%';
Query OK, 0 rows affected (0.00 sec)

5. Verify 'dmapi' user got created and it's permissions:

MariaDB [mysql]> select Host, User from user where User='dmapi';
+------+-------+
| Host | User  |
+------+-------+
| %    | dmapi |
+------+-------+
1 row in set (0.00 sec)
   
```   

4.4.2 TrilioVault Datamover container 

4.4.2.1 This should get installed on all compute nodes

4.4.2.2 Following diretcories/volumes needs to get mounted from host to triliovault datamover container

```
  - /etc/ceph/                        [or equivalent directory/volume]  
    If you are using 'Ceph Storage' as cinder/nova backend. We use ceph.conf and cinder ceph user keyring
  - /etc/iscsi/    
    If you are using iscsi as cinder/nova backend.
  - /var/lib/nova/
  - /etc/nova/                        [or equivalent directory/volume]
  - /var/lib/iscsi/                   
  - /var/lib/libvirt/                 
  - /etc/multipath/                   
    If multipath enabled on cinder/nova backend.
  - /etc/multipath.conf               
    If multipath enabled on cinder/nova backend.
  - /etc/tvault-contego/              [or equivalent directory/volume]
    If you are running your devops code on host and not on container.
  - /var/triliovault-mounts 
    If you are running your devops code on host and not on container
  - trilio datamover log directory as per your preference. default: '/var/log/nova/'
    If you are running your devops code on host and not on container   
```



4.4.3 TrilioVault Horizon Plugin container

4.4.3.1 This should replace existing OpenStack horizon container image (Provided you used same horizon image as base     image for triliovault horizon plugin image creation).
