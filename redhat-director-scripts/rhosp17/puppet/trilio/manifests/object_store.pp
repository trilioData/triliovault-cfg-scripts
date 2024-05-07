class trilio::object_store ( 
  $vault_data_dir                  = "/var/lib/nova/triliovault-mounts",
  $backup_targets_1                  = [],
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

$backup_targets = [
  {
    backup_target_name    => 'S3_BT1',
    backup_target_type    => 's3',
    is_default            => true,
    s3_type               => 'ceph_s3',
    s3_access_key         => 'ACCESSKEY1',
    s3_secret_key         => 'SECRETKEY1',
    s3_region_name        => 'REGION1',
    s3_bucket             => 'trilio-qa',
    s3_endpoint_url       => 'https://cephs3.triliodata.demo',
    s3_signature_version  => 'default',
    s3_auth_version       => 'DEFAULT',
    s3_ssl_enabled        => true,
    s3_ssl_verify         => true
  },
  {
    backup_target_name    => 'S3_BT2',
    backup_target_type    => 's3',
    is_default            => true,
    s3_type               => 'amazon_s3',
    s3_access_key         => 'ACCESSKEY2',
    s3_secret_key         => 'SECRETKEY2',
    s3_region_name        => 'REGION2',
    s3_bucket             => 'trilio-qa',
    s3_endpoint_url       => 'ENDPOINT_URL2',
    s3_signature_version  => 'default',
    s3_auth_version       => 'DEFAULT',
    s3_ssl_enabled        => true,
    s3_ssl_verify         => true
  }
]
    
      class {'trilio::object_store::config':}
}
