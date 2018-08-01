## Command to build container
```
docker build --build-arg triliovault_version=3.0.73 --build-arg triliovault_release=3.0 \
--build-arg redhat_username=<redhat_subscription_username> --build-arg redhat_password=<redhat_subscription_password> \
--build-arg redhat_pool_id=8a85f9815f01591e015f01777826485f  -t shyambiradar/trilio-datamover:queens .
```

## Command to run container
```
docker run  -v /etc/nova:/etc/nova -v /usr/share/nova:/usr/share/nova -v /var/log/nova/:/var/log/nova/ -v /usr/lib64:/usr/lib64 -v /usr/sbin:/usr/sbin \
-v /usr/bin:/usr/bin --network host --privileged=true -it --name debug11 shyambiradar/datamover:queens nfs 192.168.1.33:/mnt/tvault nolock,soft,timeo=180,intr
```
