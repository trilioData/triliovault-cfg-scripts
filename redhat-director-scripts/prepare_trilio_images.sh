#!/bin/bash


docker pull docker.io/trilio/trilio-datamover:ditest

docker tag docker.io/trilio/trilio-datamover:ditest 192.168.122.151:8787/trilio/trilio-datamover:ditest

docker push 192.168.122.151:8787/trilio/trilio-datamover:ditest

docker pull docker.io/trilio/trilio-datamover-api:ditest

docker tag docker.io/trilio/trilio-datamover-api:ditest 192.168.122.151:8787/trilio/trilio-datamover-api:ditest

docker push 192.168.122.151:8787/trilio/trilio-datamover-api:ditest
