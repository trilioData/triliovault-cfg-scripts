#!/bin/bash

set -e

if [ $# -lt 1 ];then
   echo "Script takes exactly 1 argument"
   echo -e "./add-backup-target.sh <CONFIG_MAP_YAML_FILE_PATH>"
   exit 1
fi

CONFIG_MAP_FILE=$1


## Create config map to hold input parameters
oc apply -f $CONFIG_MAP_FILE


## Create custom service resource
oc apply -f trilio-add-backup-target-service.yaml


## Trigger deployment
oc apply -f trilio-add-backup-target-deployment.yaml
