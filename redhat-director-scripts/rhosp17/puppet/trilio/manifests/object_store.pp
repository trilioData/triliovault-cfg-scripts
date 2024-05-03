class trilio::object_store ( 
  $vault_data_dir                  = "/var/lib/nova/triliovault-mounts",
  $backup_targets                  = [],
  $backup_target_type              = 'nfs',
  $s3_type                         = 'amazon_s3',
  $s3_accesskey                    = undef,
  $s3_secretkey                    = undef,
  $s3_region_name                  = undef,
  $s3_bucket                       = undef,
  $s3_endpoint_url                 = undef,
  $s3_signature_version            = 'default',
  $s3_auth_version                 = 'DEFAULT',
  $s3_ssl_enabled                  = 'False',
  $step                            = lookup('step'),
  $s3_ssl_verify                   = true,
) {
    tag 'trilioobjectstoreconfig'
    
      class {'trilio::object_store::config':}
}
