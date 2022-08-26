Service endpoint customization
==============================

If a user needs to regenerate the endpoint map for any particular reason,
they can run this script to output the updated endpoint map.

How to update the map
---------------------

Change the location of the templates if a custom path is being used that
contains an updated network/endpoints/

```
bash generate_endpoint_map.sh /usr/share/openstack-tripleo-heat-templates
```

This script outputs a endpoint_map.yaml file. If you need to use a
generated one, be sure to update the OS::TripleO::EndpointMap value in the
included trilio_env*.yaml file.

Service endpoints and TLS
-------------------------

In order to change the endpoints when also deploying with TLS enabled,
a user will need to include the correct trilio_env_tls*.yaml file which will
update the ports and hostnames for the trilio endpoints.

TLS Everywhere
--------------

Use the following as part of the deployment command to enable the tls everywhere
endpoint configuration


```
openstack overcloud deploy \
   ...SNIP...
   -e $PATH_TO/trilio_env_tls_everywhere_dns.yaml
```


TLS Public DNS
--------------

Use the following as part of the deployment command to enable the tls only on
the public endpoints



```
openstack overcloud deploy \
   ...SNIP...
   -e $PATH_TO/trilio_env_tls_endpoints_public_dns_osp13.yaml
```



TLS Public IP
-------------

Use the following as part of the deployment command to enable the tls only on
the public endpoints with IP addresses

```
openstack overcloud deploy \
   ...SNIP...
   -e $PATH_TO/trilio_env_tls_endpoints_public_ip_osp13.yaml
```


