**Pre/Post install steps to install tvault-horizon-plugin pacakge on RHEL/Centos:**

1. Create a trilio.repo file at path -/etc/yum.repo.d/trilio.repo with following content.

    *[trilio]*
    
    name=Trilio Repository

    baseurl=http:<TVAULT_APPLIANCE_IP>:8085/yum-repo/queens/

    enabled=1

    gpgcheck=0

2. Execute follwoing commands to makesure trilio's pacakges are availible controller node.

    *yum makecache*
    
    *yum list | grep -i tvault-**

3. Install python-wrokloadmgr and tvault-horizon-plugin with follwoing commands.

    *yum install python-workloadmgrclient*
    
    *yum install tvault-horizon-plugin*
    
4. Download triliovault-script-repo public repository from https://github.com/trilioData/triliovault-cfg-scripts to working directory(<triliovault-cfg-repo-absolute-path>) on controller node.    
    
5. Copy triliovault-horizon files from triliovault-cfg-repos to openstack dashboad path.

    *cd <triliovault-cfg-repo-absolute-path>/triliovault-cfg-scripts/ansible/roles/ansible-horizon-plugin/files/*
    
    *cp tvault_panel_group.py tvault_admin_panel_group.py tvault_panel.py tvault_settings_panel.py tvault_admin_panel.py /usr/share/openstack_dashboard/openstack_dashboard/local/enabled/*
    
    *cp tvault_filter.py /usr/share/openstack_dashboard/openstack_dashboard/templatetags/tvault_filter.py*
    
6. Restart httpd webserver using command - service httpd restart

7. Copy sync_static.py to /tmp

    *cd <triliovault-cfg-repo-absolute-path>/triliovault-cfg-scripts/ansible/roles/ansible-horizon-plugin/files/*
    
    *cp sync_static.py /tmp*
    
8. Execute following commands.

    *cd /usr/share/openstack-dashboard*
    
    *./manage.py shell < /tmp/sync_static.py &> /dev/null*
    
    *rm -rf /tmp/sync_static.py*

























