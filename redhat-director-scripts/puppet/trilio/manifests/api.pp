class trilio::api {
    tag 'dmapiconfig'

    file { "/etc/dmapi/dmapi.conf":
        ensure  => present,
        content => template('trilio/dmapi.erb'),
    }
}
