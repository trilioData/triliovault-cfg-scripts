[client]
# RabbitMQ connection
# Supported schemes: amqp://, amqps://, rabbit://, rabbitmq://, rabbit+ssl://
rabbitmq_url = amqp://openstack:PASSWORD@rabbitmq-host:5672/

# Database connection
db_url = mysql+pymysql://workloadmgr:PASSWORD@db-host:3306/workloadmgr

# Node identifier (optional, default: auto-detected hostname)
# If not specified, DMS will auto-detect the hostname
# node_id = controller

# Request timeout in seconds (optional, default: 60)
request_timeout = 60

# Log level (optional, default: INFO)
log_level = INFO

# Log file path (optional, default: /var/log/trilio-dms/trilio-dms-client.log)
# Directory is created automatically if it does not exist
log_file = /var/log/trilio-dms/trilio-dms-client.log

# Log file max size in bytes before rotation (optional, default: 26214400 = 25 MB)
log_max_bytes = 26214400

# Number of rotated log backups to keep (optional, default: 5)
log_backup_count = 5

# Database connection pool size (optional, default: 20)
db_pool_size = 20

# Database max overflow connections (optional, default: 40)
db_max_overflow = 40

# Database pool recycle time in seconds (optional, default: 3600)
db_pool_recycle = 3600
