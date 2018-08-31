#!/bin/bash -x


if [ ! -f /var/lib/config-data/triliodmapi/etc/dmapi/dmapi.conf ]; then
    echo "Before running this script, create dmapi.conf file at :\"/var/lib/config-data/triliodmapi/etc/dmapi/dmapi.conf\""
    exit 1
fi

if [ ! -d /var/lib/config-data/puppet-generated/nova/etc/nova ]; then
   echo "Script is expecting nova.conf to be available at /var/lib/config-data/puppet-generated/nova/etc/nova"
fi

docker run -v /var/lib/config-data/puppet-generated/nova/etc/nova:/etc/nova:ro \
-v /var/lib/config-data/triliodmapi/etc/dmapi/:/etc/dmapi:ro -v /usr/sbin:/usr/sbin -v /usr/bin:/usr/bin -v /bin:/bin \
-v /sbin:/sbin --network host --privileged=true \
-dt --name dmapi shyambiradar/trilio-dmapi:queens
