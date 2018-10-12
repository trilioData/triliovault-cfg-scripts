**Pre/Post install steps to install datamover-API pacakge on RHEL/Centos:**

1. Create a trilio.repo file at path -/etc/yum.repo.d/trilio.repo with following content.

    *[trilio]*
    
    name=Trilio Repository

    baseurl=http:<TVAULT_APPLIANCE_IP>:8085/yum-repo/queens/

    enabled=1

    gpgcheck=0

2. Execute follwoing commands to makesure trilio's pacakges are availible controller node.

    *yum makecache*
    
    *yum list | grep -i dmapi*

3. Install dmapi pacakge with follwoing commands.

    *yum install dmapi*
    
4. Create following datamover_url at /tmp/datamover_url file.
    
    *[DEFAULT]*
    
    *dmapi_link_prefix = http://<dmapi_enpoint_ip>:<port>*
    
    *dmapi_enabled_ssl_apis = sample_dmapi_enabled_ssl_apis*
    
    *[wsgi]*
    
    *ssl_cert_file = sample_ssl_cert_file*
    
    *ssl_key_file = sample_ssl_key_file*
    

5. Provide nova user access to dmapi.log file & execute populate conf command.

    *chown -R nova:nova /usr/bin/dmapi/dmapi.log*
    
    *populate-conf*
    
6. Create tvault-datamover api 

    [Unit]
    
    Description=TrilioData DataMover API service
    
    After=tvault-datamover-api.service
    
    [Service]
    
    User=nova
    
    Group=nova
    
    Type=simple
    
    ExecStart=/usr/bin/pytthon /usr/bin/dmapi
    
    KillMode=process
    
    Restart=on-failure
    
    WorkingDirectory=/var/run
    
    [Install]
    
    WantedBy=multi-user.target
    
7. Daemon-reload , Enable & restart tvault-datamover-api service   

    systemctl daemon-reload
    
    systemctl enable tvault-datamover-api.service
          
    systemctl restart tvault-datamover-api.service
