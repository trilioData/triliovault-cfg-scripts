#!/bin/bash

set -e
if [ $# -lt 2 ];then
   echo "Script takes exactly 2 arguments"
   echo -e "./create-templates-delete-backup-target.sh <BACKUP_TARGET_NAME> <BACKUP_TARGET_TYPE>"
   exit 1
fi



BACKUP_TARGET_NAME=$1
BACKUP_TARGET_TYPE=$2

mkdir -p ${BACKUP_TARGET_NAME}

cp trilio-delete-backup-target-deployment.yaml trilio-delete-backup-target-service.yaml ${BACKUP_TARGET_NAME}/

cd ${BACKUP_TARGET_NAME}/
ORIGINAL_BACKUP_TARGTE_NAME=$BACKUP_TARGET_NAME
BACKUP_TARGET_NAME=$(echo "$BACKUP_TARGET_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/_/-/g')
sed -i "s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/g" trilio-delete-backup-target-deployment.yaml
sed -i "s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/g" trilio-delete-backup-target-service.yaml
