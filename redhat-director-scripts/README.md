### Clone repository
```
git clone https://github.com/trilioData/triliovault-cfg-scripts.git
cd triliovault-cfg-scripts/redhat-director-scripts/
```
### Get your overcloud deploy command
This command will look like this. If you have already deployed cloud you should have it.
If you want to deploy new cloud, you need to prepare this command.

```
openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /home/stack/templates/network-environment.yaml \
-e /home/stack/templates/storage-environment.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log
```

### Find path of roles_data.yaml
By default this file present on undercloud at location: "/usr/share/openstack-tripleo-heat-templates/roles_data.yaml"
If you have customized your roles_data file, get it's abosolute path. This path will be used in in next steps.
 
### Prepare trilio env file
Edit `trilio_env.yaml` to set all details required for trilio.


### Prepare artifacts 
Run prepare_artifacts.sh script as shown below, it will do following things
- Takes tripelO puppet module from undercloud(/etc/puppet/modules/tripleo) and adds trilio puppet, heat templates to it. It does not modify any existing code of tripleo module. It creats a copy of it in cureent directory
- Takes 'trilio' puppet module from "puppet/trilio" directory of trilio repository, both modules tripleO and trilio will get copied in 
trilio_puppet_modules directory in current directory 
- Then scripyt will use "upload-puppet-modules" tools of RHOSP and will upload both puppet modules to overcloud.
- Finally it will take roles_data file path as input and will add trilio services under controller and compute role.
```
./prepare_artifacts.sh <Roles_data_file_path>
./prepare_artifacts.sh /usr/share/openstack-tripleo-heat-templates/roles_data.yaml
```

### Add trilio components to deployment command.
Note that user needs to add trilio env file using '-e' option and new roles_data file using '-r' option.
After this command will look like:
```
/openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /home/stack/templates/network-environment.yaml \
-e /home/stack/templates/storage-environment.yaml \
-e ${basedir}/trilio_env.yaml \
-r ${basedir}/roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log
```

### Run your deploy command
```
/openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /home/stack/templates/network-environment.yaml \
-e /home/stack/templates/storage-environment.yaml \
-e ${basedir}/trilio_env.yaml \
-r ${basedir}/roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log
```
