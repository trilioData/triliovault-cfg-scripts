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

set -euo pipefail

export OS_PROJECT_ID=$(openstack project show -f value -c id "${OS_PROJECT_NAME}")

backup_target_type="{{ .Values.trilio_backup_target.backup_target_type }}"
backup_target_name="{{ .Values.trilio_backup_target.backup_target_name }}"

function get_backup_target_id() {
  workloadmgr backup-target-type-show "$backup_target_name" -f json | jq -r '.backup_targets_id'
}

function delete_target() {
  local backup_target_id
  backup_target_id=$(get_backup_target_id)

  if [ -n "$backup_target_id" ] && workloadmgr backup-target-show "$backup_target_id" >/dev/null 2>&1; then
    echo "Deleting backup target ID: $backup_target_id"
    workloadmgr backup-target-delete "$backup_target_id" || {
      echo "Warning: Failed to delete backup target '$backup_target_id'"
    }
  else
    echo "Backup target ID not found or already deleted. Skipping."
  fi
}

if [[ "$backup_target_type" == "nfs" || "$backup_target_type" == "s3" ]]; then
  delete_target
else
  echo "Unsupported backup target type: $backup_target_type"
  exit 1
fi

echo "Cleanup for ${backup_target_name} complete."
