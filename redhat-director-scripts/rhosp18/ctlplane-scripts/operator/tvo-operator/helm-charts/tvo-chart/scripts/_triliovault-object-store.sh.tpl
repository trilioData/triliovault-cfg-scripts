#!/bin/bash

set -e

COMMAND="${@:-start}"

function start () {

cat > /etc/triliovault-object-store/triliovault-object-store-dynamic.conf <<EOF

[${BACKUP_TARGET_NAME}]
s3_access_key = ${S3_ACCESS_KEY}
s3_secret_key = ${S3_SECRET_KEY}
EOF

  ## Start triliovault object store service if backup target type is s3
  /usr/bin/python3 /usr/bin/s3vaultfuse.py \
    --config-file=/etc/triliovault-object-store/triliovault-object-store.conf \
    --config-file=/etc/triliovault-object-store/triliovault-object-store-dynamic.conf
  sleep 20s
  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault-object-store service: $status"
    exit $status
  fi

}

function stop () {
  kill -TERM 1
}

$COMMAND
