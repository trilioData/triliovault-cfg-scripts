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

mkdir -p /var/log/triliovault/datamover
chown -R nova:nova /var/log/triliovault /var/trilio

if [ -n $NFS_SHARES ]
then
touch /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-dynamic-values.conf
echo vault_storage_nfs_export

tee > /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-dynamic-values.conf << EOF
[DEFAULT]
vault_storage_nfs_export = $NFS_SHARES
EOF

fi