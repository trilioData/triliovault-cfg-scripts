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
--build-arg redhat_pool_id=8a85f9815f01591e015f01777826485f  -t shyambiradar/trilio-datamover:queens .
```

## Command to run container

If you are running this container on non RHOSP setup, create /var/log/containers/nova directory on node where you want to run this container.
```
docker run  -v /etc/:/etc/ -v /var/log/containers/nova:/var/log/nova --network host --privileged=true -it --name debug shyambiradar/trilio-datamover:queens nfs 192.168.1.33:/mnt/tvault nolock,soft,timeo=180,intr
```
