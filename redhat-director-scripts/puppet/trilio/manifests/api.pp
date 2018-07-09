class trilio::api (
     $tvault_virtual_ip    = undef,
     $tvault_version       = undef
){

    $version_numbers= split($tvault_version, '\.')
    $tvault_release = "${version_numbers[0]}.${version_numbers[1]}"

    package { 'tvault-contego-api':
        ensure => latest,
        provider => 'rpm',
        source => "/var/tmp/tvault-contego-api-${tvault_version}-${tvault_release}.noarch.rpm",
        notify => Service['nova-api'],
    }


}
