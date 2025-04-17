#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -ex

export OS_PROJECT_ID=$(openstack project show -f value -c id "${OS_PROJECT_NAME}")
## Check and create backup target
backup_target_type="{{ .Values.trilio_backup_target.backup_target_type | quote }}"
backup_target_name="{{ .Values.trilio_backup_target.backup_target_name | default "default-nfs-name" }}"

if [ "$backup_target_type" = "nfs" ]; then
    nfs_ip="{{ .Values.trilio_backup_target.nfs_server | default "" }}"
    nfs_path="{{ .Values.trilio_backup_target.nfs_shares | default "" }}"
    if [ -z "$nfs_ip" ] || [ -z "$nfs_path" ]; then
        echo "Error: NFS IP or path is missing!"
        exit 1
    fi

    echo "Checking if NFS backup target '${backup_target_name}' exists..."
    if workloadmgr backup-target-type-show "${backup_target_name}" 2>&1 | grep -q "No backuptargettype"; then
        echo "NFS backup target '${backup_target_name}' does not exist. Creating it..."
        workloadmgr backup-target-create --type nfs --filesystem-export "${nfs_ip}:${nfs_path}" --btt-name "${backup_target_name}"
        
        if [ $? -eq 0 ]; then
            echo "NFS backup target '${backup_target_name}' created successfully."
        else
            echo "Failed to create NFS backup target '${backup_target_name}'."
            exit 1
        fi
    else
        echo "NFS backup target '${backup_target_name}' already exists. Skipping creation."
        exit 0
    fi

elif [ "$backup_target_type" = "s3" ]; then
    s3_bucket="{{ .Values.trilio_backup_target.s3_bucket | default "" }}"
    s3_endpoint="{{ .Values.trilio_backup_target.s3_endpoint_url | default "" }}"

    if [ -z "$s3_bucket" ]; then
        echo "Error: S3 bucket name is missing!"
        exit 1
    fi

    echo "Checking if S3 backup target '${backup_target_name}' exists..."
    if workloadmgr backup-target-type-show "${backup_target_name}" 2>&1 | grep -q "No backuptargettype"; then
        echo "S3 backup target '${backup_target_name}' does not exist. Creating it..."
        
        if [ -n "$s3_endpoint" ]; then
            workloadmgr backup-target-create --type s3 --s3-bucket "${s3_bucket}" --s3-endpoint-url "${s3_endpoint}" --btt-name "${backup_target_name}"
        else
            workloadmgr backup-target-create --type s3 --s3-bucket "${s3_bucket}" --btt-name "${backup_target_name}"
        fi

        if [ $? -eq 0 ]; then
            echo "S3 backup target '${backup_target_name}' created successfully."
        else
            echo "Failed to create S3 backup target '${backup_target_name}'."
            exit 1
        fi
    else
        echo "S3 backup target '${backup_target_name}' already exists. Skipping creation."
        exit 0
    fi
else
    echo "Unsupported backup target type: ${backup_target_type}"
    exit 1
fi
