class trilio::api {

    package { 'tvault-contego-api':
        ensure   => present,
        provider => 'yum',
        notify   => Service['nova-api'],
    }
}
