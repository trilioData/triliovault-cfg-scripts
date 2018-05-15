These ansible scripts are designed to configure tvault cluster, deploy trilioVault extension and install trilioVault horizon plugin
=====================================================================================================================================

===Pre-requisites to use these scripts===============================
1.	Ansible server

2.	Ansible’s host inventory file should have three host goups, one is "controller" listing all controller nodes, next is "compute" listing all compute nodes and last is "horizon" listing all horizon nodes
        For Ex. Your <base-dir>/environments/hosts file should look like this
        ---/environment/hosts------
        [controller]
        192.168.1.21
       
        [compute]
        192.168.1.29
       
        [horizon]
        192.168.1.21

        [localhost]
        127.0.0.1
        --------------------------
         
3.	On all these nodes (Compute, controller and horizon) Ansible server’s passwordless authentication setup should be done(Server should be able to run ansible scripts on these nodes).

4.      Tvault appliance deployed in cloud environment and floating ip which is accessible from ansible server should be assigned to all tvault nodes.


===Steps to use these scripts================
1.	Download/clone ansible directory in your playbook directory , change working directory to ansible

2.	Edit vars.yml file to configure necessary parameters. 

3.	Execute master-install.yml to configure tvault nodes and install contego and horizon plugin. Use following command.

        ansible-playbook main-install.yml -i environments/hosts --tags "all-install"

5.      See "Usage" section to know how this scripts can be used to install contego,horizon,tvault-configuration cluster seperately 

====Usage=============================================================================================================

For end to end installation of trilliovault(datamover extension,horizon,contego-api and tvault-configuation):

To install all above tasks
ansible-playbook main-install.yml -i environments/hosts --tags "all-install"

To uninstall all above tasks
ansible-playbook main-install.yml -i environments/hosts --tags "all-uninstall"

==========================================================

For installing tvault-horizon on openstack-horizon node
ansible-playbook horizon-plugin.yml -i environments/hosts --tags "horizon-plugin-install"

For uninstalling tvault-horizon on openstack-horizon node
ansible-playbook horizon-plugin.yml -i environments/hosts --tags "horizon-plugin-uninstall"

==========================================================

For installing datamover extension on compute node
ansible-playbook contego-extension.yml -i environments/hosts --tags "contego-extension-install"

For uninstalling datamover extension on compute node
ansible-playbook contego-extension.yml -i environments/hosts --tags "contego-extension-uninstall"

=========================================================

For installing contego-api on controller node
ansible-playbook contego-api-install.yml -i environments/hosts --tags "contego-api-install"

For uninstalling contego-api on controller node
ansible-playbook contego-api-install.yml -i environments/hosts --tags "contego-api-uninstall"

