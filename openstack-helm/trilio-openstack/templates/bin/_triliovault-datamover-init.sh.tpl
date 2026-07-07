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
chown nova:nova /var/log/triliovault /var/trilio /var/lib/trilio

# Ensure the triliovault-mounts directory exists and has the correct permissions for the nova user (UID 42424)
mkdir -p /var/lib/trilio/triliovault-mounts
chown -R 42424:42424 /var/lib/trilio/triliovault-mounts
chmod 775 /var/lib/trilio/triliovault-mounts

touch /tmp/pod-shared-triliovault-datamover/triliovault-datamover-dynamic-values.conf

<INJECT_INIT_FILES>
