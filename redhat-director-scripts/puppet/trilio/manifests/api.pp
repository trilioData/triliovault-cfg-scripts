class trilio::api (
     $tvault_virtual_ip    = undef,
     $tvault_version       = undef
){

    package { 'tvault-contego-api':
        ensure   => latest,
        provider => 'yum',
#        notify   => Service['nova-api'],
    }


}
