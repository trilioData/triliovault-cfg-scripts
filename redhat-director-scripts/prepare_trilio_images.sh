#!/bin/bash


docker pull docker.io/shyambiradar/trilio-datamover:queens

docker tag docker.io/shyambiradar/trilio-datamover:queens 192.168.122.151:8787/shyambiradar/trilio-datamover:queens

docker push 192.168.122.151:8787/shyambiradar/trilio-datamover:queens
