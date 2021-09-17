
 **Install steps for Trilio Datamover Service**
 
 This trilio component should be installed on all compute nodes.

**1. Pre-requisites**

  i)Select which storage type you want to use to store your snapshots.
  TrilioVault supports NFS, Amazon S3 and Ceph S3. This would be your backup target type.

  ii) Make sure that your compute nodes have connectivity to the Internet.
  This is required because our yum, apt package repos are on cloud.

**Note**: *Perform following steps on all compute nodes*

**2. Setup Trilio repository**

  Clone the repository:

    git clone https://github.com/trilioData/triliovault-cfg-scripts.git
    
    cd triliovault-cfg-scripts/
   
  *If platform is RHEL/CentOs*
  
    cp kolla-ansible/trilio-datamover-api/trilio.repo /etc/yum.repos.d/trilio.repo

  *If platform is Ubuntu*
  
    echo "deb [trusted=yes] https://apt.fury.io/triliodata-4-1/ /" >> /etc/apt/sources.list.d/trilio.list

    apt-get update

**3. Install Trilio Datamover extension package**

   *If platform is RHEL/CentOS*
   
    yum makecache

    - Python 2
    yum install tvault-contego puppet-triliovault -y
   
    - Python3
    dnf install -y python3-tvault-contego puppet-triliovault python3-s3fuse-plugin
   
   *If platform is Ubuntu*
   
    apt-get update

    - Python2
    apt-get install -y tvault-contego --allow-unauthenticated
    
    - Python3
    apt-get install -y python3-tvault-contego python3-s3-fuse-plugin --allow-unauthenticated

    
**4. Populate datamover conf file**

     mkdir -p /etc/tvault-contego
     
     chown -R nova:nova /etc/tvault-contego/
     
     
     
  i)If backup target is NFS, You will need a NFS share: for ex: 192.168.16.14:/var/share1
  Edit /etc/tvault-contego/tvault-contego.conf file and replace 'NFS_SHARE' string with your actual
  NFS share value
     
     cp conf-files/tvault_contego_conf_nfs /etc/tvault-contego/tvault-contego.conf

     vi /etc/tvault-contego/tvault-contego.conf

  ii)If backup target is amazon S3 
 
     cp conf-files/tvault_contego_conf_amazon_s3 /etc/tvault-contego/tvault-contego.conf

     vi /etc/tvault-contego/tvault-contego.conf
  
  Edit file /etc/tvault-contego/tvault-contego.conf and set values of following parameters.
  
  - S3_ACCESS_KEY
  - S3_SECRET_KEY
  - S3_REGION_NAME
  - S3_BUCKET
  

  iii)If backup target is any other supported S3 storage:
  
     cp conf-files/tvault_contego_conf_ceph_s3 /etc/tvault-contego/tvault-contego.conf

     vi /etc/tvault-contego/tvault-contego.conf

  Edit /etc/tvault-contego/tvault-contego.conf for the same
  You will need set following parameters:
  
  - S3_ACCESS_KEY
  - S3_SECRET_KEY
  - S3_REGION_NAME
  - S3_BUCKET
  - S3_ENDPOINT_URL
  - S3_SSL_ENABLED
  
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

     cp kolla-ansible/trilio-datamover/trilio.filters /usr/share/nova/rootwrap/trilio.filters

**8. Configure log rotation for datamover logs**

    cp redhat-director-scripts/docker/trilio-datamover/log-rotate-conf /etc/logrotate.d/tvault-contego

**9. Create service init files**
  If your compute node using systemd init mechinism:

  *If backup target is 'NFS'
  
    cp conf-files/tvault-contego.service.nfs /etc/systemd/system/tvault-contego.service
    
    # Update python path (In line ExecStart=) in above service file with correct value as per your enviornment.
   
  *If backup target is 'S3'*
  
    cp conf-files/tvault-contego.service.s3 /etc/systemd/system/tvault-contego.service    

    cp conf-files/tvault-object-store.service /etc/systemd/system/tvault-object-store.service 

    # Update python path (In line ExecStart=) in above service file with correct value as per your enviornment. 

  **Note**: You need validate above init files, executable paths and conf file paths. If necessary you can edit python install directory path in above init files as per platform you are using


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
   
