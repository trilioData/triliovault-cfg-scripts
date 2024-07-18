#!/bin/bash -x
set -ex
DB_ROOT_USER="{{- .Values.database.common.root_user_name -}}"
DB_ROOT_PASSWORD="{{- .Values.database.common.root_password -}}"
DB_HOST="{{- .Values.database.common.host -}}"
DB_NAME="{{- .Values.database.wlm_api.database -}}"
DB_USER="{{- .Values.database.wlm_api.user -}}"
DB_PASSWORD="{{- .Values.database.wlm_api.password -}}"
# Create the database
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

# Create the user
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"

# Grant privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
#mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
# Flush privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "FLUSH PRIVILEGES;"
sleep 200m
# Database Sync
exec alembic --config /etc/triliovault-wlm/triliovault-wlm.conf upgrade head
status=$?
if [ $status -ne 0 ]; then
  echo "TrilioVault wlm database init failed"
  exit $status
else
  echo "TrilioVault wlm database init completed successfully"
fi
