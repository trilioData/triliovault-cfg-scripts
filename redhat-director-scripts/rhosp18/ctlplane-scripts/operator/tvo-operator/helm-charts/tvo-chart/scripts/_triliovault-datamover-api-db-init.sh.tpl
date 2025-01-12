#!/bin/bash

set -ex

DB_ROOT_USER="{{- .Values.database.common.root_user_name -}}"
DB_ROOT_PASSWORD="{{- .Values.database.common.root_password -}}"
DB_HOST="{{- .Values.database.common.host -}}"
DB_NAME="{{- .Values.database.datamover_api.database -}}"
DB_USER="{{- .Values.database.datamover_api.user -}}"
DB_PASSWORD="{{- .Values.database.datamover_api.password -}}"
# Create the database
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

# Create the user
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"

# Grant privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
#mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
# Flush privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "FLUSH PRIVILEGES;"
# Database Sync
exec /usr/bin/python3 /usr/bin/dmapi-dbsync --config-file /etc/triliovault-datamover/triliovault-datamover-api.conf
status=$?
if [ $status -ne 0 ]; then
  echo "TrilioVault datamover api db init failed with retrun code $status"
  exit $status
else
  echo "TrilioVault datamover api db init completed successfully"
fi

