#!/bin/bash

set -e

DB_ROOT_USER="{{- .Values.database.common.root_user_name -}}"
DB_HOST="{{- .Values.database.common.host -}}"
DB_NAME="{{- .Values.database.datamover_api.database -}}"
DB_USER="{{- .Values.database.datamover_api.user -}}"
# Create the database
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;"

DB_EXISTS=$(mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -N -B -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME';")

if [ -n "$DB_EXISTS" ]; then
    echo "Database exists. Updating character set and collation..."
    mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "ALTER DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    echo "Database character set and collation updated."
else
    echo "Database does not exist."
fi



# Create the user
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"

# Grant privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
#mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
# Flush privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "FLUSH PRIVILEGES;"
# Database Sync

tee > /tmp/triliovault-datamover-api-dynamic.conf << EOF

[database]
connection = mysql+pymysql://${DMAPI_DATABASE_USER}:${DB_PASSWORD}@${DMAPI_DATABASE_HOST}:${DMAPI_DATABASE_PORT}/${DMAPI_DATABASE_NAME}

EOF


exec /usr/bin/python3 /usr/bin/dmapi-dbsync --config-file /tmp/triliovault-datamover-api-dynamic.conf --config-file /etc/triliovault-datamover/triliovault-datamover-api.conf
status=$?
if [ $status -ne 0 ]; then
  echo "TrilioVault datamover api db init failed with retrun code $status"
  exit $status
else
  echo "TrilioVault datamover api db init completed successfully"
fi

