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

touch /tmp/pod-shared-triliovault-datamover/triliovault-datamover-dynamic-values.conf

{{- if and (eq .Values.conf.triliovault.backup_target_type "nfs") (.Values.conf.triliovault.nfs.multi_ip_nfs) -}}
{{ printf "\n" }}
if [ -n $NFS_SHARE ]
then
tee > /tmp/pod-shared-triliovault-datamover/triliovault-datamover-dynamic-values.conf << EOF
[DEFAULT]
vault_storage_nfs_export = $NFS_SHARE
EOF

fi

{{- end }}

# --------------------------------------------
# 1 & 2. Setup nova-libvirt.conf and nova-hypervisor.conf
# Only if distro == mosk
# --------------------------------------------
{{- if eq (default "" .Values.distro) "mosk" }}

# Set default values
migration_interface="{{ default "mcc-lcm" .Values.conf.datamover.libvirt.live_migration_interface }}"
listen_tls="{{ default "false" .Values.conf.datamover.libvirt.listen_tls }}"
hypervisor_interface="{{ default "mcc-lcm" .Values.conf.datamover.libvirt.hypervisor_host_interface }}"

touch /etc/nova/nova.conf.d/nova-libvirt.conf
if [[ -n "$migration_interface" ]]; then
    migration_address=$(ip a s $migration_interface | grep 'inet ' | awk '{print $2}' | awk -F "/" '{print $1}')
fi

qemu_connection_type="qemu+tcp"
if [[ "$listen_tls" == "true" ]]; then
    qemu_connection_type="qemu+tls"
fi

if [[ -n "$migration_address" ]]; then
    cat <<EOF > /etc/nova/nova.conf.d/nova-libvirt.conf
[libvirt]
live_migration_inbound_addr = $migration_address
connection_uri = "${qemu_connection_type}://${migration_address}/system"
EOF
    chgrp nova /etc/nova/nova.conf.d/nova-libvirt.conf
else
    echo "Migration address is not set."
    exit 1
fi

# Prepare nova-hypervisor.conf
if [[ -z "$hypervisor_interface" ]]; then
    hypervisor_interface=$(ip -4 route list 0/0 | awk -F 'dev' '{ print $2; exit }' | awk '{ print $1 }') || exit 1
fi

hypervisor_address=$(ip a s "$hypervisor_interface" | grep 'inet ' | awk '{print $2}' | awk -F "/" '{print $1}')
if [ -z "$hypervisor_address" ]; then
    echo "Var my_ip is empty"
    exit 1
fi

tee > /etc/nova/nova.conf.d/nova-hypervisor.conf << EOF
[DEFAULT]
my_ip = $hypervisor_address
EOF

chgrp nova /etc/nova/nova.conf.d/nova-hypervisor.conf

{{- end }}
