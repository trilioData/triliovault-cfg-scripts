**Install TrilioVault Horizon Plugin**

This plugin is responsible to facilitate triliovault GUI on OpenStack horizon.
It is supposed to be installed on all horizon nodes.

**Notes**: *Perform following steps on all horizon nodes.*


**1. Pre-requisites**

  i)You should have launched at-least one TrilioVault VM and this VM should have l3 connectivity with
  OpenStack compute, controller and horizon nodes.
  Get IP address of TrilioVault VM. For example, we assume it's 192.168.14.56. 
  
**2. Setup Trilio repository**

Clone the repository:

   git clone https://github.com/trilioData/triliovault-cfg-scripts.git
   
   cd triliovault-cfg-scripts/
   
  *If platform is RHEL/CentOs*
  Create /etc/yum.repos.d/trilio.repo file with following content.
  Make sure, you replace "192.168.14.56" with actual TrilioVault VM IP from your enviornment
  
    cp ansible/roles/ansible-datamover-api/templates/trilio.repo /etc/yum.repos.d/trilio.repo

  *If platform is Ubuntu*
  
    cp ansible/roles/ansible-datamover-api/templates/trilio.list /etc/apt/sources.list/trilio.list

**3. Install Trilio Datamover extension package**

   *If platform is RHEL/CentOS*
   
      yum makecache

      yum install tvault-horizon-plugin python-workloadmgrclient
   
   *If platform is Ubuntu*
   
      apt-get update

      apt-get install tvault-horizon-plugin
    
      apt-get install python-workloadmgrclient
    
**4. Copy config files to OpenStack dashboard directory**

    cd ansible/roles/ansible-horizon-plugin/files/
    
    cp tvault_panel_group.py tvault_admin_panel_group.py tvault_panel.py tvault_settings_panel.py tvault_admin_panel.py /usr/share/openstack_dashboard/openstack_dashboard/local/enabled/
    
    cp tvault_filter.py /usr/share/openstack_dashboard/openstack_dashboard/templatetags/tvault_filter.py
    
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

























