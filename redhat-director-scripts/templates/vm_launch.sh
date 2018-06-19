#!/bin/bash -x


openstack server create --flavor m1.tiny --image "c236af28-77d6-4d53-92f6-f64fe8e83fc6" --security-group default --nic net-id=ec5d2ff0-90ce-499f-870b-1e4d13bd1fa3 cirros-vm --debug
