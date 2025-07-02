#!/bin/bash

set -e

function start () {

  echo "[INFO] Starting s3vaultfuse at $(date)"
  /usr/bin/python3 /usr/bin/s3vaultfuse.py --config-file=/etc/trilio-object-store/trilio-object-store.conf
  sleep 20s
  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start trilio-object-store service: $status"
    exit $status
  fi

}

function stop () {
  echo "[INFO] stop() triggered at $(date)"
  echo "[INFO] Running S3 object store unmount (lazy)"

  VAULT_DIR=$(grep '^vault_data_directory[[:space:]]*=' /etc/trilio-object-store/trilio-object-store.conf | cut -d'=' -f2- | xargs)

  echo "[INFO] VAULT_DIR is $VAULT_DIR"
  if [[ -n "$VAULT_DIR" ]]; then
    umount -l "$VAULT_DIR" && \
      echo "[INFO] Unmounted $VAULT_DIR" || \
      echo "[WARN] Failed to unmount $VAULT_DIR"
  else
    echo "[WARN] vault_data_directory not found in config file"
  fi
  kill -TERM 1
}

# Use the first argument to dispatch to the correct function
case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  *)
    echo "Unknown command: $1"
    exit 1
    ;;
esac
