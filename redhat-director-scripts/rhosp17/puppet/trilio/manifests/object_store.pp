class trilio::object_store ( 
  $vault_data_dir                  = "/var/lib/nova/triliovault-mounts",
  $backup_targets                  = [],
  $step                            = lookup('step'),
) {
    tag 'trilioobjectstoreconfig'
    
      class {'trilio::object_store::config':}
}
