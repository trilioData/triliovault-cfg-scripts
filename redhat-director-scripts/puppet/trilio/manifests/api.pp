class trilio::api (
     $tvault_virtual_ip    = undef,
     $tvault_version       = undef
){

    package { 'tvault-contego-api':
        ensure   => latest,
        provider => 'rpm',
        source   => "http://${tvault_virtual_ip}/triliovault-datamover-api.noarch.rpm",
#        notify   => Service['nova-api'],
    }


}
