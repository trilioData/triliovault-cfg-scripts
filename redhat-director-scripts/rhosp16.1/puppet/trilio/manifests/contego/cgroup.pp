class trilio::contego::cgroup inherits trilio::contego {


    if "${is_cpu_exists}" == "true" {
        if "${is_trilio_exists}" != "true" {
             file { "/sys/fs/cgroup/cpu/trilio/cpu.shares":
                 ensure  => 'directory',
                 owner   => $contego_user,
                 group   => $contego_group,
                 mode    => '0644',
                 source  => 'puppet:///modules/trilio/cpu.shares',
                 require => File["/sys/fs/cgroup/cpu/trilio"],
             }
        }
        file { "/sys/fs/cgroup/cpu/trilio":
             ensure  => 'directory',
             owner   => $contego_user,
             group   => $contego_group,
             mode    => '0644',
             recurse => true,
             before  => Exec['Change ownership of trilio dir'],
        }

        exec { 'Change ownership of trilio dir':
            command => "/usr/bin/chown -R ${contego_user}:${contego_group} /sys/fs/cgroup/cpu/trilio/",
            path    => ['/usr/bin','/usr/sbin','/usr/local/bin'],
        }

    }
   

         
    if "${is_blkio_exists}" == "true" {
        file { "/sys/fs/cgroup/blkio/trilio":
             ensure => 'directory',
             owner  => $contego_user,
             group  => $contego_group,
             mode   => '0644',
             recurse => true,
        } ->

        exec { 'Change ownership of trilio blkio dir':
            command => "/usr/bin/chown -R ${contego_user}:${contego_group} /sys/fs/cgroup/blkio/trilio/",
            path    => ['/usr/bin','/usr/sbin','/usr/local/bin'],
        }

    }           

}
