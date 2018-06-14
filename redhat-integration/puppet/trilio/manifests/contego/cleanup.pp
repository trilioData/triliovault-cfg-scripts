class trilio::contego::cleanup inherits trilio::contego {
    require trilio::contego::validate
    require trilio::contego::install
    require trilio::contego::postinstall
    require trilio::contego::cgroup
    require trilio::contego::service

    if $backup_target_type == 'nfs' {
        $nfs_shares_list.each |Integer $index, String $nfs_share| {
            exec {"Delete directory: /tmp/test_dir_${index}":
                command  => "rm -rf /tmp/test_dir_${index}",
                path     => ['/usr/bin','/usr/sbin'],
            }
        }
    }
}
