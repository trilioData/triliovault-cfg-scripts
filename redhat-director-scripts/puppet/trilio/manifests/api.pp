class trilio::api (
     $tvault_virtual_ip    = undef,
     $tvault_version       = undef
){

    $version_numbers= split($tvault_version, '\.')
    $tvault_release = "${version_numbers[0]}.${version_numbers[1]}"

    file { '/var/trilio-rpms':
        ensure => 'directory',
        mode   => '0755'
    }->

    file { "/var/trilio-rpms/tvault-contego-api-${tvault_version}-${tvault_release}.noarch.rpm":
        source  => "http://${tvault_virtual_ip}/triliovault-datamover-api.noarch.rpm",
        require => File["/var/trilio-rpms"]
    }->

    package { 'tvault-contego-api':
        ensure   => latest,
        provider => 'rpm',
        source   => "/var/trilio-rpms/tvault-contego-api-${tvault_version}-${tvault_release}.noarch.rpm",
        notify   => Service['nova-api'],
        require  => File["/var/trilio-rpms/tvault-contego-api-${tvault_version}-${tvault_release}.noarch.rpm"]
    }


}
