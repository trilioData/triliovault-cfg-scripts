#!/bin/bash


docker pull docker.io/shyambiradar/trilio-datamover:queens

docker tag 5cfbb2b76d49 192.168.122.151:8787/shyambiradar/trilio-datamover

docker push 192.168.122.151:8787/shyambiradar/trilio-datamover
