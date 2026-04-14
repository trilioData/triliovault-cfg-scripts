[server]

# Node identifier (optional, default: auto-detected hostname)
# If not specified, DMS will use socket.gethostname()
# node_id = controller

# Keystone auth URL
auth_url = {{ .Values.keystone.common.auth_url }}

# Enable quorum queues for RabbitMQ (optional, default: True)
rabbit_quorum_queue = {{ .Values.rabbitmq.cluster.rabbit_quorum_queue }}

# Barbican SSL verification (optional, default: False)
# Set to True to enable SSL certificate verification for Barbican API
# Set to False to disable SSL verification (useful for self-signed certificates)
barbican_ssl_verify = {{ .Values.keystone.common.ssl_verify }}

# Custom CA bundle for Barbican (optional, default: None)
# If specified, uses this CA bundle path for SSL verification instead of system CA
barbican_ca_bundle = /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

# Log level (optional, default: INFO)
log_level = INFO

# Log file path (optional, default: /var/log/trilio-dms/trilio-dms-server.log)
# Directory is created automatically if it does not exist
log_file = /var/log/triliovault/trilio-dms-server.log

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
rootwrap_conf = /etc/triliovault-dms/rootwrap.conf

# Number of worker threads for parallel request processing (optional, default: 10)
# Requests for different (host, backup_target_id) pairs run in parallel.
# Requests for the same pair are serialized.
worker_threads = 10
