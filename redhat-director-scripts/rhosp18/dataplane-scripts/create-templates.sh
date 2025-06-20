#!/bin/bash

set -e
if [ $# -lt 2 ];then
   echo "Script takes exactly 2 arguments"
   echo -e "./create-templates.sh <BACKUP_TARGET_NAME> <BACKUP_TARGET_TYPE>"
   exit 1
fi



BACKUP_TARGET_NAME=$1
BACKUP_TARGET_TYPE=$2

rm -rf ${BACKUP_TARGET_NAME}
mkdir ${BACKUP_TARGET_NAME}

cp trilio-add-backup-target-deployment.yaml trilio-add-backup-target-service.yaml ${BACKUP_TARGET_NAME}/
cp cm-trilio-backup-target-${BACKUP_TARGET_TYPE}.yaml ${BACKUP_TARGET_NAME}/cm-trilio-backup-target.yaml

cd ${BACKUP_TARGET_NAME}/
ORIGINAL_BACKUP_TARGTE_NAME=$BACKUP_TARGET_NAME
BACKUP_TARGET_NAME=$(echo "$BACKUP_TARGET_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/_/-/g')
sed -i "s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/g" trilio-add-backup-target-deployment.yaml
sed -i "s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/g" trilio-add-backup-target-service.yaml
sed -i "/^  name: /s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/" cm-trilio-backup-target.yaml
sed -i "s/<BACKUP_TARGET_NAME>/${ORIGINAL_BACKUP_TARGTE_NAME}/g" cm-trilio-backup-target.yaml
