#!/bin/bash

set -ex
export HOME=/tmp

cat > /etc/ceph/ceph.client.{{ .Values.ceph.rbdUser }}.keyring << EOF
[client.{{ .Values.ceph.rbdUser }}]
{{- if .Values.ceph.keyring }}
    key = {{ .Values.ceph.keyring }}
{{- else }}
    key = $(cat /tmp/client-keyring)
{{- end }}
EOF

exit 0
