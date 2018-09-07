#!/bin/bash


docker pull docker.io/trilio/trilio-datamover:queens

docker tag docker.io/trilio/trilio-datamover:queens 192.168.122.151:8787/trilio/trilio-datamover:queens

docker push 192.168.122.151:8787/trilio/trilio-datamover:queens

docker pull docker.io/trilio/trilio-datamover-api:queens

docker tag docker.io/trilio/trilio-datamover-api:queens 192.168.122.151:8787/trilio/trilio-datamover-api:queens

docker push 192.168.122.151:8787/trilio/trilio-datamover-api:queens
