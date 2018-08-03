## Assumptions
This container is only designed for and tested on Redhat OpenStack Platform 13.

## Pre-requisites
1. Redhat OpenStack Platform 13 setup deployed with container approach
2. To build container you will need redhat subscription with OpenStack Platform suite

## Command to build container
```
git clone <repo>
cd /path/to/redhat-director-scripts/docker/trilio-datamover/
docker build \
--build-arg redhat_username=<redhat_subscription_username> --build-arg redhat_password=<redhat_subscription_password> \
--build-arg redhat_pool_id=<Redhat_OpenStack_Pool_ID>  -t shyambiradar/trilio-datamover:queens .
```

## Command to run container

If you are running this container on non RHOSP setup, create /var/log/containers/nova directory on node where you want to run this container.
#### For NFS as backup target:
```
docker run -v /usr/sbin:/usr/sbin -v /usr/bin:/usr/bin -v /bin:/bin -v /sbin:/sbin --network host --privileged=true -it --name debug shyambiradar/trilio-datamover:queens nfs 192.168.1.33:/mnt/tvault nolock,soft,timeo=180,intr
```
#### For Amazon S3 as backup target:
```
docker run -v /usr/sbin:/usr/sbin -v /usr/bin:/usr/bin -v /bin:/bin -v /sbin:/sbin --network host --privileged=true -it --name debug shyambiradar/trilio-datamover:queens amazon_s3 <s3_access_key_id> <s3_secret_access_key> <s3_region_name> <s3_bucket>
```
#### Redhat Ceph S3 as backup target
```
docker run -v /usr/sbin:/usr/sbin -v /usr/bin:/usr/bin -v /bin:/bin -v /sbin:/sbin --network host --privileged=true -it --name debug shyambiradar/trilio-datamover:queens ceph_s3 <s3_access_key_id> <s3_secret_access_key> <s3_region_name> <s3_endpoint_url > <s3_bucket>
<s3_ssl>
```
