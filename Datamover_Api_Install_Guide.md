**Install Trilio Datamover Api Service**

TrilioVault Datamover Api is a control plane of TrilioVault datamover service.
Typically user needs to install this service on controller nodes. But tecnically you can install this service on any 
node like any other openstack service.

Node where we are installing dmapi service, we will call it as datamover api nodes. 


**Note**: *Perform following steps on all datamover api nodes*

**1. Pre-requisites**

  i) Make sure that your datamover api nodes(planned) have connectivity to the Internet.
  This is required because our yum, apt package repos are on cloud.

**2. Setup Trilio package repository**

Clone the repository on controller node:

    git clone https://github.com/trilioData/triliovault-cfg-scripts.git
   
    cd triliovault-cfg-scripts/
   
  *If platform is RHEL/CentOs*
  
      cp kolla-ansible/trilio-datamover-api/trilio.repo /etc/yum.repos.d/trilio.repo

  *If platform is Ubuntu*
  
      echo "deb [trusted=yes] https://apt.fury.io/triliodata-4-1/ /" >> /etc/apt/sources.list.d/trilio.list
      
      apt-get update

**3. Install and configure Trilio Datamover Api Service**

   *If platform is RHEL/CentOS*
   
      yum makecache
      
      - Python2
      yum install dmapi -y
      
      - Python3
      yum install python3-dmapi -y
   
   *If platform is Ubuntu*
   
      apt-get update

      - Python2
      apt-get install dmapi
      
      - Python3
      apt-get install -y python3-dmapi --allow-unauthenticated
    
**4. Populate triliovault datamover api service configuration file - /etc/dmapi/dmapi.conf**

After installing datamover api rpm/debian package, a sample conf file gets create at location:
/etc/dmapi/dmapi.conf

      vi /etc/dmapi/dmapi.conf

User needs to edit it and fill all necessary parameters.

Here are the details of all parameters


| Parameter   | Description | Default Value |
| :---        |    :----:   |          :--- |
| [DEFAULT]     |        |    |
| dmapi_workers     | Number of dmapi process workers       | 16   |
| transport_url   | message queue url        | And more      |
| dmapi_link_prefix   | Text        | And more      |
| dmapi_enabled_ssl_apis   | Keep this empty        | Empty      |
| dmapi_listen_port   | dmapi service listen port        | 8784      |
| dmapi_enabled_apis   | USE_DEFAULT_VALUE        | dmapi      |
| bindir   | USE_DEFAULT_VALUE         | /usr/bin      |
| instance_name_template   | USE_DEFAULT_VALUE         | instance-%08x      |
| dmapi_listen  | IP address on which dmapi service listens        | empty      |
| my_ip   | IP address on which dmapi service listens       | empty     |
| rootwrap_config   | USE_DEFAULT_VALUE       | /etc/dmapi/rootwrap.conf      |
| debug   | If you don't want debug logs, make it False        | Ttrue      |
| log_file   | You can use customize this     | /var/log/dmapi/dmapi.log     |
| log_dir   |  You can use customize this       | /var/log/dmapi      |
|           |             |                       |
| [wsgi]                 |           |            |
| ssl_cert_file   | TLS cert file path        | /opt/stack/data/CA/int-ca/devstack-cert.crt      |
| ssl_key_file   | TLS key file path       | /opt/stack/data/CA/int-ca/private/devstack-cert.key      |
| api_paste_config   | Text        | /etc/dmapi/api-paste.ini      |
|           |             |                       |
| [database]   |         |       |
| connection   | Database connection of dmapi user        | mysql+pymysql://root:project1@127.0.0.1/dmapi?charset=utf8      |
|           |             |                       |
| [keystone_authtoken]   |        |      |
| memcached_servers   | Text        | Empty      |
| signing_dir   | Text        | /var/cache/dmapi      |
| cafile   | Text        | /opt/stack/data/ca-bundle.pem      |
| project_domain_name   | 'dmapi' user's project domain name        | Default      |
| project_name   | 'dmapi' user's project name        | service      |
| user_domain_name   | 'dmapi' user domain name       | Default      |
| username   |  USE_DEFAULT_VALUE  |   dmapi  |
| password   | password        |   project1    |
| auth_url   | Keystone auth url        | https://controller/identity      |
| auth_type   | Keystone auth type        | password      |
| auth_uri   | Keystone Auth uri        | http://controller:5000      |
| project_domain_id | |  default |
| www_authenticate_uri | |  http://controller:5000 |
| insecure   |  USE_DEFAULT_VALUE       | True      |
|           |             |                       |
| [oslo_messaging_notifications]   |       |       |
| transport_url   | Text        | rabbit://dmapi:password@localhost:5672      |
| driver   | Text        | messagingv2     |
|           |             |                       |
| [oslo_middleware]   |        |       |
| enable_proxy_headers_parsing   | USE_DEFAULT_VALUE        | True      |


**5. Create dmapi log directory:**

        mkdir -p /var/log/dmapi
     
        chown -R nova:nova /var/log/dmapi
    
**6. Create service init file: /etc/systemd/system/tvault-datamover-api.service**


        cp conf-files/tvault-dmapi.service /etc/systemd/system/


- Update service file with correct python executable path at line - "ExecStart=/usr/bin/python /usr/bin/dmapi-api"

        vi /etc/systemd/system/tvault-dmapi.service     
    
**7. Start dmapi service**

        systemctl daemon-reload
    
        systemctl enable tvault-dmapi.service
          
        systemctl restart tvault-dmapi.service
    
**8. Verify Installation**

    i) Verify that tvault-dmapi service is started
    
          systemctl status tvault-dmapi
          
    ii) Verify that no error appears in log file - '/var/log/dmapi/dmapi.log'     
