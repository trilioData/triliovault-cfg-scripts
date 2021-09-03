**Install TrilioVault Horizon Plugin**

This plugin is responsible to facilitate triliovault GUI on OpenStack horizon.
It is supposed to be installed on all horizon nodes.

**Note**: *Perform following steps on all horizon nodes.*


**1. Pre-requisites**
  i) Make sure that your horizon nodes have connectivity to the Internet. 
  This is required because our yum, apt package repos are on cloud. 
  
**2. Setup Trilio repository**

Clone the repository:

   git clone https://github.com/trilioData/triliovault-cfg-scripts.git
   
   cd triliovault-cfg-scripts/
 
   git checkout stable/3.4
   
  *If platform is RHEL/CentOs*

    cp kolla-ansible/trilio-datamover-api/trilio.repo /etc/yum.repos.d/trilio.repo

  *If platform is Ubuntu*
  
    echo "deb [trusted=yes] https://apt.fury.io/triliodata-3-4/ /" >> /etc/apt/sources.list.d/trilio.list

**3. Install Trilio Datamover extension package**

Note: workloadmgrclient package gets installed as a dependency of the triliovault horizon package.

   *If platform is RHEL/CentOS*
   
      yum makecache

      - Python2
      yum install tvault-horizon-plugin python-workloadmgrclient
   
      - Python3
      dnf install python3-tvault-horizon-plugin-el8
      
   *If platform is Ubuntu*
   
      apt-get update

      - Python2
      apt-get install tvault-horizon-plugin
      
      - Python3
      apt-get install -y python3-tvault-horizon-plugin python3-workloadmgrclient --allow-unauthenticated
    
**4. Copy config files to OpenStack dashboard directory**

    cd ansible/roles/ansible-horizon-plugin/files/
    
    cp tvault_panel_group.py tvault_admin_panel_group.py tvault_panel.py tvault_settings_panel.py tvault_admin_panel.py /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
    
    cp tvault_filter.py /usr/share/openstack-dashboard/openstack_dashboard/templatetags/tvault_filter.py
    
**5. Restart webserver**
   We need to restart webserver(used by horizon) to reflect changes.
   
  *On RHLE/CentOS based OpenStack*
  
    systemctl restart httpd

  *On Ubuntu based OpenStack*
     
     systemctl restart apache2
     
**6. Copy sync_static.py to /tmp**

    cd ansible/roles/ansible-horizon-plugin/files/
    
    cp sync_static.py /tmp
    
  Execute following commands.

    cd /usr/share/openstack-dashboard
    
    ./manage.py shell < /tmp/sync_static.py &> /dev/null
    
    rm -rf /tmp/sync_static.py

**7. Verify Installation**
    
    Login to OpenStack dashboard.
    
    After successful installation of triliovault horizon plugin, you should see a new tab named "Backups" in tenant space of OpenStack dashboard.
    
    In admin space you should see "Backups-Admin" tab. These two tabs belong to TrilioVault.
    If you do not see "Backups" tab, then installation was not successful. 






















