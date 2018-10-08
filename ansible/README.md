These ansible scripts are designed to configure tvault cluster, deploy trilioVault extension and install trilioVault horizon plugin
=====================================================================================================================================

===Pre-requisites to use these scripts===============================
1.	Ansible server with ansible version > 2.4.0
         
2.	On all clients nodes (Compute, controller and horizon) Ansible server’s passwordless authentication setup should be done(Server should be able to run ansible scripts on these nodes).  
        For reference : https://www.tecmint.com/ssh-passwordless-login-using-ssh-keygen-in-5-easy-steps/

3.      Tvault appliance deployed in cloud environment and floating ip which is accessible from ansible server should be assigned to all tvault nodes.

===Steps to use these scripts================
1.	Download tvault ansible scripts tarball from tvault appliance's downloads tab shown in UI.
        Extract tarball and change working directory to tvault-pure-ansible-scripts/ansible/

2.      Ansible’s host inventory file should have three host goups, one is "controller" listing all controller nodes, next is "compute" listing all compute nodes and last is "horizon" listing all horizon nodes
        For Ex. Your <base-dir>/environments/hosts file should look like this
        ---/environments/hosts------
        [controller]
        192.168.1.1

        [compute]
        192.168.1.1

        [horizon]
        192.168.1.1

        [localhost]
        127.0.0.1
        --------------------------
3.	Edit environments/group_vars/all/vars.yml file to configure necessary parameters. 

4.	Execute main-install.yml to configure tvault nodes and install contego and horizon plugin. Use following command.

        ansible-playbook main-install.yml -i environments/hosts --tags "all-install"

5.      See "Usage" section to know how this scripts can be used to install contego,horizon,tvault-configuration cluster seperately 

====Usage================================================

For end to end installation of trilliovault(datamover extension,horizon,contego-api and tvault-configuation):

To install all above tasks

ansible-playbook main-install.yml -i environments/hosts --tags "all-install"

To uninstall all above tasks

ansible-playbook main-install.yml -i environments/hosts --tags "all-uninstall"

==== tags can be used with playbook =====================

For installing tvault-horizon on openstack-horizon node

ansible-playbook main-install.yml -i environments/hosts --tags "horizon"

For uninstalling tvault-horizon on openstack-horizon node
ansible-playbook main-install.yml -i environments/hosts --tags "horizon-uninstall"

==========================================================

For installing datamover extension on compute node
ansible-playbook main-install.yml -i environments/hosts --tags "contego-extension"

For uninstalling datamover extension on compute node
ansible-playbook main-install.yml -i environments/hosts --tags "contego-extension-uninstall"

=========================================================

For installing datamover-api on controller node
ansible-playbook main-install.yml -i environments/hosts --tags "datamover-api"

For uninstalling datamover-api on controller node
ansible-playbook main-install.yml -i environments/hosts --tags "datamover-api-uninstall"

