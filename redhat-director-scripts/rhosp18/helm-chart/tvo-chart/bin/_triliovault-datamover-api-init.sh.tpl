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


## datamover api conf file for my_ip parameter
chown -R dmapi:dmapi /var/log/triliovault
touch /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf

tee > /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf << EOF
[DEFAULT]
dmapi_link_prefix = http://${POD_IP}:8784
dmapi_listen = $POD_IP
my_ip = $POD_IP
EOF


