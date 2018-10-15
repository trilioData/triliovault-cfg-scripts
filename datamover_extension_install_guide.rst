
 **Install steps for Trilio Datamover Extension**
 This trilio component sits on compute node and performs backups and recovery.
 User should install this plugin all compute nodes.

**1. Pre-requisites**

  i)You should have launched at-least one TrilioVault VM and this VM should have l3 connectivity with
  OpenStack compute, controller and horizon nodes.
  Get IP address of TrilioVault VM. For example, we assume it's 192.168.14.56. 

  ii)Select which storage type you want to use to store your snapshots.
  TrilioVault supports NFS, Amazon S3 and Ceph S3. This would be your backup target type.

**Notes**: *Perform following steps on all compute nodes.*

**2. Setup Trilio repository**

  Clone the repository:
    git clone https://github.com/trilioData/triliovault-cfg-scripts.git
    
    cd triliovault-cfg-scripts
   
  *If platform is RHEL/CentOs*
  Create /etc/yum.repos.d/trilio.repo file with following content.
  Make sure, you replace "192.168.14.56" with actual TrilioVault VM IP from your enviornment
  
    cp ansible/roles/ansible-datamover-api/templates/trilio.repo /etc/yum.repos.d/trilio.repo

  *If platform is Ubuntu*
  
    cp ansible/roles/ansible-datamover-api/templates/trilio.list /etc/apt/sources.list/trilio.list

**3. Install Trilio Datamover extension package**

   *If platform is RHEL/CentOS*
   
    yum makecache

    yum install tvault-contego
   
   *If platform is Ubuntu*
   
    apt-get update

    apt-get install contego

    apt-get install tvault-contego
   
   **Note**: "tvault-contego" is the name of our datamover extension package.
    
**4. Populate datamover conf file**

  i)If backup target is NFS, You will need a NFS share: for ex: 192.168.16.14:/var/share1

  Download conf template with below command and edit NFS_SHARE value and save.
     
   cp conf-files/tvault_contego_conf_nfs /etc/tvault-contego/tvault-contego.conf

  ii)If backup target is amazon S3, you will need four values:  acess_key, secret_key, region_name and 
  bucket_name.

  Download conf template with below command and edit s3 credentials to provide actual values.
     
      cp conf-files/tvault_contego_conf_amazon_s3 /etc/tvault-contego/tvault-contego.conf 

  iii)If backup target is amazon S3, you will need four values:  acess_key, secret_key, endpoint_url, bucket_name and if ssl     enabled on s3 endpoint

  Download conf template with below command and edit s3 credentials to provide actual values.
     
      cp conf-files/tvault_contego_conf_ceph_s3 /etc/tvault-contego/tvault-contego.conf 

**5. Setup password-less sudo access for nova user**
  Trilio datamover process runs with 'nova' user and datamover process is repsonsible to perform backup and recovery.
  To perform backups and recovery, sometimes it needs previlaged access. For that we need to add this user to suoders
  with passwordless access.

    cp redhat-director-scripts/docker/trilio-datamover/nova-sudoers /etc/sudoers.d/nova-trilio

**6. Add 'nova' user to necessary groups**
  Trilio datamover process runs with 'nova' user and datamover process is repsonsible to perform backup and recovery .
  For this, 'nova' user needs to be added to approrpriate system groups to get access to hypervisor and storage.
  
   usermod -a -G kvm,qemu,libvirt,disk,nova nova

**7. Create necessary directories**
  These directories will be used by Trilio datamover to mount the backup target and related work.
  
   mkdir -p /var/triliovault-mounts
  
   chown nova:nova /var/triliovault-mounts
  
   mkdir -p /var/triliovault
  
   chown nova:nova /var/triliovault
  
   chmod 777 /var/triliovault-mounts
  
   chmod 777 /var/triliovault

**8. Configure log rotation for datamover logs**

    cp redhat-director-scripts/docker/trilio-datamover/log-rotate-conf /etc/logrotate.d/tvault-contego

**9. Create service init files**
  If your compute node using systemd init mechinism:
  
    cp conf-files/tvault-contego.service /etc/systemd/system/
   
  *If backup target is s3, you need copy object-store service file too. In case of nfs you only need tvault-contego service.*
  
    cp conf-files/tvault-object-store.service /etc/systemd/system/  

  **Note**: You need edit python install directory path in above init files as per platform you are using


**10. Start datamover services**

    systemctl daemon-reload
    
    systemctl enable tvault-contego.service
          
    systemctl restart tvault-contego.service

    *If backup target is s3, start tvault-object-store service too*
    
    systemctl restart tvault-object-store.service
    
 **11. Verify Installation**
  *Make Sure trilio services are started*
  If Backup target is 'NFS' only 'tvault-contego' service will be running.
   
    systemctl status tvault-contego
   
  If backup target if S3, 'tvault-contego' and 'tvault-object-store' both services will be running
   
    systemctl status tvault-contego tvault-object-store
   
  *Make sure backup target is mounted on compute node*
  
  If backup target is NFS, mount looks like following(Highlighted)
  
    [root@compute site-packages]# df -h
    
    **192.168.1.33:/mnt/tvault 1008G  611G  347G  64% /var/triliovault-mounts/MTkyLjE2OC4xLjMzOi9tbnQvdHZhdWx0**

  If backup target is S3, mount looks like following
    root@compute1:~# df -h
    
    **TrilioVault                     -     -  0.0K    - /var/triliovault-mounts**
      
   **Log files**
   /var/log/nova/tvault-contego.log
   
