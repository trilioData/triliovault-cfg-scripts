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
   
  *If platform is RHEL/CentOs*

    cp kolla-ansible/trilio-datamover-api/trilio.repo /etc/yum.repos.d/trilio.repo

  *If platform is Ubuntu*
  
    echo "deb [trusted=yes] https://apt.fury.io/triliodata-4-1/ /" >> /etc/apt/sources.list.d/trilio.list

**3. Install TrilioVault Horizon plugin package**

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

  - Clone the horizon-tvault-plugin repository. This is a private github repository of TrilioVault, you can ask for credentials(username and personal access token) to sales/support contact person.

    cd ../

    git clone https://github.com/trilioData/horizon-tvault-plugin.git
    
    cd horizon-tvault-plugin/usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
    
    cp tvault_panel_group.py tvault_admin_panel_group.py tvault_panel.py tvault_settings_panel.py tvault_admin_panel.py /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
    
    cd ../../templatetags/
    
    cp tvault_filter.py /usr/share/openstack-dashboard/openstack_dashboard/templatetags/tvault_filter.py
    
     
**5. Run collectstatic**

  
- If it's python2

    /usr/bin/python /usr/share/openstack-dashboard/manage.py collectstatic --clear --noinput
    /usr/bin/python /usr/share/openstack-dashboard/manage.py compress --force

- If it's python3
    /usr/bin/python3 /usr/share/openstack-dashboard/manage.py collectstatic --clear --noinput
    /usr/bin/python3 /usr/share/openstack-dashboard/manage.py compress --force
    

**6. Restart webserver**
   We need to restart webserver(used by horizon) to reflect changes.
   
  *On RHLE/CentOS based OpenStack*
  
    systemctl restart httpd

  *On Ubuntu based OpenStack*
     
     systemctl restart apache2


**7. Verify Installation**
    
    Login to OpenStack dashboard.
    
    After successful installation of triliovault horizon plugin, you should see a new tab named "Backups" in tenant space of OpenStack dashboard.
    
    In admin space you should see "Backups-Admin" tab. These two tabs belong to TrilioVault.
    If you do not see "Backups" tab, then installation was not successful. 






















