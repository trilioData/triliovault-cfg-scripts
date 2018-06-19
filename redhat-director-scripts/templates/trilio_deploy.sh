#!/bin/bash
 
upload-puppet-modules -d trilio_puppet_modules


openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /home/stack/templates/network-environment.yaml \
-e /home/stack/templates/storage-environment.yaml \
-e /home/stack/templates/tripleo-integration/trilio_env.yaml \
-r /home/stack/templates/tripleo-integration/trilio_roles_data.yaml \
--control-scale 1 --compute-scale 1 --control-flavor control --compute-flavor compute \
--ntp-server 0.north-america.pool.ntp.org --neutron-network-type vxlan --neutron-tunnel-types vxlan \
--validation-errors-fatal --validation-warnings-fatal \
--log-file overcloud_deploy.log
