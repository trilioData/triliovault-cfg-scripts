1. Clone repository
git clone https://github.com/trilioData/triliovault-cfg-scripts.git

2. Change directory
cd triliovault-cfg-scripts.git

3. Prepare your overcloud deploy command(without trilio components), it will look like following command

openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /home/stack/templates/network-environment.yaml \
-e /home/stack/templates/storage-environment.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log

4. Prepare roles data file
This roles data file is standard roles data file from RHOSP 10. It is taken from "/usr/share/openstack-tripleo-heat-templates/roles_data.yaml"
If you have customized your roles_data file, in step 7, provide path of roles_data to prapare_artifacts.sh, it will
add trilio services to roles_data file and will create a copy of it. It will not modify original copy of roles_data.
 
5. Prepare trilio env file
Edit trilio_env.yaml to set all details required for trilio.

6. Add trilio components to deployment command.
Note that user needs to add trilio env file using '-e' option and new roles_data file using '-r' option.
After this command will look like:


7. Run prepare_artifacts.sh this file will take tripelO puppet module from undercloud and trilio puppet module from repo and will upload it to overcloud. Also it will take roles_data file as input and will add trilio services to it
./prepare_artifacts.sh

8. /openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /home/stack/templates/network-environment.yaml \
-e /home/stack/templates/storage-environment.yaml \
-e ${basedir}/trilio_env.yaml \
-r ${basedir}/roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log
