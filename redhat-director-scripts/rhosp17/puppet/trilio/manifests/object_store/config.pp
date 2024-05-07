class trilio::object_store::config inherits trilio::object_store {
    tag 'trilioobjectstoreconfig'

      file { '/etc/triliovault-object-store/':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
      }->
      file { "/etc/triliovault-object-store/object_store_logging.conf":
          ensure  => present,
          content => template('trilio/object_store_logging_conf.erb'),
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
      }

# Iterate over backup_targets parameter
    $backup_targets.each |$target| {
      # Check if backup_target_type = s3
      if $target['backup_target_type'] == 's3' {
        if $target['s3_type'] == 'amazon_s3' {
          $backup_target_mount_point = base64('encode', $target['s3_bucket'])
        }
        else {
          $s3_domain_name = regsubst($target['s3_endpoint_url'], '^https?://', '')
          $bucket_name = $target['s3_bucket']
          $ceph_s3_str = "$s3_domain_name/$bucket_name"
          $backup_target_mount_point = base64('encode', $ceph_s3_str)
        }
        file { "/etc/triliovault-object-store/s3-cert-${target['backup_target_name']}.pem":
          ensure => 'present',
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
          source => "puppet:///modules/trilio/s3-cert-${target['backup_target_name']}.pem",
        }

        $conf_file_name = "/etc/triliovault-object-store/triliovault-object-store_${target['backup_target_name']}.conf"

        # Create conf file
        file { $conf_file_name:
          ensure  => present,
          owner  => '42436',
          group  => '42436',
          mode   => '0644',
          content => epp('trilio/triliovault_object_store.conf.epp', {
            backup_target_type    => $target['backup_target_type'],
            backup_target_name    => $target['backup_target_name'],
            backup_target_mount_point => $backup_target_mount_point,
            s3_accesskey          => $target['s3_access_key'],
            s3_secretkey          => $target['s3_secret_key'],
            s3_bucket             => $target['s3_bucket'],
            s3_region_name        => $target['s3_region_name'],
            s3_auth_version       => $target['s3_auth_version'],
            s3_signature_version  => $target['s3_signature_version'],
            s3_ssl_enabled        => $target['s3_ssl_enabled'],
            s3_ssl_verify         => $target['s3_ssl_verify'],
            s3_type               => $target['s3_type'],
            s3_endpoint_url       => $target['s3_endpoint_url'],
            vault_data_dir        => $vault_data_dir,
          }),
        }
      }


    }


}

