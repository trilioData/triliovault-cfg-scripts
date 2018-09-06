## Assumptions
This container is only designed for and tested on Redhat OpenStack Platform 13.

## Pre-requisites
1. Redhat OpenStack Platform 13 setup deployed with container approach
2. To build container you will need redhat subscription with OpenStack Platform suite

## Command to build container
```
git clone <repo>
cd /path/to/redhat-director-scripts/docker/trilio-dmapi/
docker build \
--build-arg redhat_username=<redhat_subscription_username> --build-arg redhat_password=<redhat_subscription_password> \
--build-arg redhat_pool_id=<Redhat_OpenStack_Pool_ID>  -t shyambiradar/trilio-dmapi:queens .
```

## Command to run container

If you are running this container on non RHOSP setup, create /var/log/containers/nova directory on node where you want to run this container.

##Step1:
Create tvault-contego.conf with all parameters(backup target) at location "/var/lib/config-data/triliodm/etc/tvault-contego/tvault-contego.conf"
Use puppet for that:(use puppet/trilio)
puppet agent --test --tags dmapiconfig

#### For NFS as backup target:
```
docker run -v /var/lib/config-data/puppet-generated/nova_libvirt/etc/nova:/etc/nova:ro \
-v /var/run/libvirt/:/var/run/libvirt/ -v /var/lib/config-data/triliodmaoi/etc/dmapi:/etc/dmapi:ro \
-v /usr/sbin:/usr/sbin -v /usr/bin:/usr/bin -v /bin:/bin \
-v /sbin:/sbin --network host --privileged=true \
-dt --name dmapi shyambiradar/trilio-dmapi:queens
```
#### For Amazon S3 as backup target:
```
docker run -v /etc/nova:/etc/nova -v /var/run/libvirt/:/var/run/libvirt/ -v /usr/sbin:/usr/sbin -v /usr/bin:/usr/bin -v /bin:/bin -v /sbin:/sbin --network host --privileged=true -it --name debug shyambiradar/trilio-datamover:queens amazon_s3 <s3_access_key_id> <s3_secret_access_key> <s3_region_name> <s3_bucket>
```
#### Redhat Ceph S3 as backup target
```
docker run -v /etc/nova:/etc/nova -v /var/run/libvirt/:/var/run/libvirt/ -v /usr/sbin:/usr/sbin -v /usr/bin:/usr/bin -v /bin:/bin -v /sbin:/sbin --network host --privileged=true -it --name debug shyambiradar/trilio-datamover:queens ceph_s3 <s3_access_key_id> <s3_secret_access_key> <s3_region_name> <s3_endpoint_url > <s3_bucket>
<s3_ssl>
```
