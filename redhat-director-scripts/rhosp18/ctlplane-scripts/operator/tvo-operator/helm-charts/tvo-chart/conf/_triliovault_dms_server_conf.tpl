[server]
# RabbitMQ connection
# Supported schemes: amqp://, amqps://, rabbit://, rabbitmq://, rabbit+ssl://
rabbitmq_url = amqp://openstack:PASSWORD@rabbitmq-host:5672/

# Node identifier (optional, default: auto-detected hostname)
# If not specified, DMS will use socket.gethostname()
# node_id = controller

# Keystone auth URL
auth_url = https://keystone:5000

# Barbican SSL verification (optional, default: False)
# Set to True to enable SSL certificate verification for Barbican API
# Set to False to disable SSL verification (useful for self-signed certificates)
barbican_ssl_verify = False

# Custom CA bundle for Barbican (optional, default: None)
# If specified, uses this CA bundle path for SSL verification instead of system CA
# barbican_ca_bundle = /path/to/ca-bundle.crt

# Log level (optional, default: INFO)
log_level = INFO

# Log file path (optional, default: /var/log/trilio-dms/trilio-dms-server.log)
# Directory is created automatically if it does not exist
log_file = /var/log/trilio-dms/trilio-dms-server.log

# Log file max size in bytes before rotation (optional, default: 26214400 = 25 MB)
log_max_bytes = 26214400

# Number of rotated log backups to keep (optional, default: 5)
log_backup_count = 5

# S3VaultFuse binary path (optional, default: /usr/bin/s3vaultfuse.py)
# If not found, will auto-detect using 'which s3vaultfuse.py'
s3vaultfuse_bin = /usr/bin/s3vaultfuse.py

# Rootwrap binary path (optional, default: /usr/bin/trilio-dms-rootwrap)
rootwrap_bin = /usr/bin/trilio-dms-rootwrap

# Rootwrap config path (optional, default: /etc/trilio-dms/rootwrap.conf)
rootwrap_conf = /etc/trilio-dms/rootwrap.conf

# SSL verification for Barbican API (optional, default: true)
barbican_ssl_verify = true

# Barbican CA bundle path (optional, default: None - uses system CA bundle)
# Use this for custom/self-signed certificates
# barbican_ca_bundle = /etc/ssl/certs/custom-ca-bundle.crt

# Number of worker threads for parallel request processing (optional, default: 10)
# Requests for different (host, backup_target_id) pairs run in parallel.
# Requests for the same pair are serialized.
worker_threads = 10
