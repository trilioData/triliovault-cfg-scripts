
    **Install steps for Trilio Datamover Extension**

**1. Pre-requisites**

  i)You should have launched at-least one TrilioVault VM and this VM should have l3 connectivity with
  OpenStack compute, controller and horizon nodes.
  Get IP address of TrilioVault VM. For example, we assume it's 192.168.14.56. 

  ii)Select which storage type you want to use to store your snapshots.
  TrilioVault supports NFS, Amazon S3 and Ceph S3. This would be your backup target type.

**2. RHEL/Centos- Setup Trilio yum repository**

  *If platform is RHEL/CentOs*
  Create /etc/yum.repos.d/trilio.repo file with following content.
  Make sure, you replace "192.168.14.56" with actual TrilioVault VM IP from your enviornment
  
    cp ansible/roles/ansible-datamover-api/templates/ /etc/yum.repos.d/trilio.repo

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
   
   *Note: "tvault-contego" is the name of our datamover extension package.*    
    
**4. Populate datamover conf file**

  i)If backup target is NFS, You will need a NFS share: for ex: 192.168.16.14:/var/share1

  Download conf template with below command and edit NFS_SHARE value and save.
     
   cp tvault_contego_conf_nfs /etc/tvault-contego/tvault-contego.conf

  ii)If backup target is amazon S3, you will need four values:  acess_key, secret_key, region_name and 
  bucket_name.

  Download conf template with below command and edit s3 credentials to provide actual values.
     
      cp tvault_contego_conf_amazon_s3 /etc/tvault-contego/tvault-contego.conf 

  iii)If backup target is amazon S3, you will need four values:  acess_key, secret_key, endpoint_url, bucket_name and if ssl     enabled on s3 endpoint

  Download conf template with below command and edit s3 credentials to provide actual values.
     
      cp tvault_contego_conf_ceph_s3 /etc/tvault-contego/tvault-contego.conf 

**5. Setup password-less sudo access for nova user**

    Copy file "redhat-director-scripts/docker/trilio-datamover/nova-sudoers" to sudoers directory.

    cp redhat-director-scripts/docker/trilio-datamover/nova-sudoers /etc/sudoers.d/nova-sudoers

**6. Add 'nova' user to necessary groups**

   usermod -a -G kvm,qemu,libvirt,disk,nova nova

**7. Create necessary directories**

  mkdir -p /var/triliovault-mounts
  
  chown nova:nova /var/triliovault-mounts
  
  mkdir -p /var/triliovault
  
  chown nova:nova /var/triliovault
  
  chmod 777 /var/triliovault-mounts
  
  chmod 777 /var/triliovault

**8. Configure log rotation for datamover logs**

    cp redhat-director-scripts/docker/trilio-datamover/log-rotate-conf /etc/logrotate.d/tvault-contego

**9. Create service init files**
  
    cp conf-files/tvault-contego.service /etc/systemd/system/
   
    *If backup target is s3, you need copy object-store service file too. In case of nfs you only need tvault-contego service.*
  
    cp conf-files/tvault-object-store.service /etc/systemd/system/  

    *Note: You need edit python install directory path in above init files as per platform you are using*  


**10. Start datamover services**

    systemctl daemon-reload
    
    systemctl enable tvault-contego.service
          
    systemctl restart tvault-contego.service

    *If backup target is s3, start tvault-object-store service too*
    
    systemctl restart tvault-object-store.service
