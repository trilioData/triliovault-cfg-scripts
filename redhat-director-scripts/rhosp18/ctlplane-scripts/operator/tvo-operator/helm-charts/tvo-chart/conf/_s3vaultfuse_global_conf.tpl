[DEFAULT]
# Storage type (default: s3)
vault_storage_type = {{ .Values.dms.s3vaultfuse.default.vault_storage_type }}

# S3 connection tuning
vault_s3_max_pool_connections = {{ .Values.dms.s3vaultfuse.default.vault_s3_max_pool_connections }}
vault_s3_read_timeout = {{ .Values.dms.s3vaultfuse.default.vault_s3_read_timeout }}
vault_s3_max_attempts = {{ .Values.dms.s3vaultfuse.default.vault_s3_max_attempts }}
vault_s3_auth_version = {{ .Values.dms.s3vaultfuse.default.vault_s3_auth_version }}
vault_s3_signature_version = {{ .Values.dms.s3vaultfuse.default.vault_s3_signature_version }}

# SSL settings (DMS overrides these via env vars by default)
vault_s3_ssl = {{ .Values.dms.s3vaultfuse.default.vault_s3_ssl }}
vault_s3_ssl_verify = {{ .Values.dms.s3vaultfuse.default.vault_s3_ssl_verify }}
vault_s3_region_name = {{ .Values.dms.s3vaultfuse.default.vault_s3_region_name }}

# FUSE / caching
vault_segment_size = {{ .Values.dms.s3vaultfuse.default.vault_segment_size }}
vault_cache_size = {{ .Values.dms.s3vaultfuse.default.vault_cache_size }}
queue_depth = {{ .Values.dms.s3vaultfuse.default.queue_depth }}
worker_pool_size = {{ .Values.dms.s3vaultfuse.default.worker_pool_size }}
vault_retry_count = {{ .Values.dms.s3vaultfuse.default.vault_retry_count }}

# Thread pool
vault_enable_threadpool = {{ .Values.dms.s3vaultfuse.default.vault_enable_threadpool }}
vault_threaded_filesystem = {{ .Values.dms.s3vaultfuse.default.vault_threaded_filesystem }}
max_uploads_pending = {{ .Values.dms.s3vaultfuse.default.max_uploads_pending }}

# Logging
vault_logging_level = {{ .Values.dms.s3vaultfuse.default.vault_logging_level }}
log_file = {{ .Values.dms.s3vaultfuse.default.log_file }}
log_config_append = {{ .Values.dms.s3vaultfuse.default.log_config_append }}
trace_function_calls = {{ .Values.dms.s3vaultfuse.default.trace_function_calls }}

# S3 bucket features
bucket_object_lock = {{ .Values.dms.s3vaultfuse.default.bucket_object_lock }}
use_manifest_suffix = {{ .Values.dms.s3vaultfuse.default.use_manifest_suffix }}
azure_immutability_enabled = {{ .Values.dms.s3vaultfuse.default.azure_immutability_enabled }}

# Metadata cache
metadata_cache_max_items = {{ .Values.dms.s3vaultfuse.default.metadata_cache_max_items }}

# System user for cache directory ownership
vault_cache_username = {{ .Values.dms.s3vaultfuse.default.vault_cache_username }}

[s3fuse_sys_admin]
helper_command = {{ .Values.dms.s3vaultfuse.s3fuse_sys_admin.helper_command }}
