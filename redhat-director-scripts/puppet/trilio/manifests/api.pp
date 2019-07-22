class trilio::api {

    package { 'tvault-contego-api':
        ensure   => latest,
        provider => 'yum',
        notify   => Service['nova-api'],
    }
}
