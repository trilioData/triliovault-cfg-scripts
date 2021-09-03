**Install Trilio Datamover Api Service**

TrilioVault Datamover Api is a control plane of TrilioVault datamover service.
Typically user needs to install this service on controller nodes. But tecnically you can install this service on any 
node like any other openstack service.

Node where we are installing dmapi service, we will call it as datamover api nodes. 


**Note**: *Perform following steps on all datamover api nodes*

**1. Pre-requisites**

  <<< i)You should have launched at-least one TrilioVault VM and this VM should have l3 connectivity with
  OpenStack compute, controller and horizon nodes.
  Get IP address of TrilioVault VM. For example, we assume it's 192.168.14.56. >>>

  ii) Make sure that your horizon nodes have connectivity to the Internet.
  This is required because our yum, apt package repos are on cloud.

**2. Setup Trilio package repository**

Clone the repository on controller node:

    git clone https://github.com/trilioData/triliovault-cfg-scripts.git
   
    cd triliovault-cfg-scripts/
    
    git checkout stable/3.4
   
  *If platform is RHEL/CentOs*
  
      cp kolla-ansible/trilio-datamover-api/trilio.repo /etc/yum.repos.d/trilio.repo

  *If platform is Ubuntu*
  
      echo "deb [trusted=yes] https://apt.fury.io/triliodata-3-4/ /" >> /etc/apt/sources.list.d/trilio.list

**3. Install and configure Trilio Datamover Api Service**

   *If platform is RHEL/CentOS*
   
      yum makecache

      yum install dmapi
   
   *If platform is Ubuntu*
   
      apt-get update

      apt-get install dmapi
    
**4. Populate triliovault datamover api service configuration file - '/etc/dmapi/dmapi.conf' **
After installing datamover api rpm/debian package, a sample conf file gets create at location:
/etc/dmapi/dmapi.conf

User needs to edit it and fill all necessary parameters.

Here are the details of all parameters.

<<<<<<<<<<<<< TODO: ADD ALL PARAMETERS AND IT's DETAILS HERE in TABULAR FORMAT >>>>>>>>>>>>>>>>>>>>>>>>>

**5. Create dmapi log directory:**
        mkdir /var/log/dmapi
     
        chown -R nova:nova /var/log/dmapi
    
**6. Create service init file: /etc/systemd/system/tvault-datamover-api.service**


        cp conf-files/tvault-datamover-api.service /etc/systemd/system/   
    
**7. Start dmapi service**

        systemctl daemon-reload
    
        systemctl enable tvault-datamover-api.service
          
        systemctl restart tvault-datamover-api.service
    
**8. Verify Installation**

    i) Verify that dmapi service is started
    
          systemctl status tvault-datamover-api
          
    ii) Verify that no error appears in log file - '/var/log/dmapi/dmapi.log'     
