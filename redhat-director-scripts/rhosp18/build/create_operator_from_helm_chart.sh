#!/bin/bash
rm -rf ../operator/tvo-operator
mkdir -p ../operator/tvo-operator
cd ../operator/tvo-operator

## Pre-requistes
#1. Operator SDK CLI installed
#2. OpenShift CLI (oc) v4.8+ installed
#3. Logged into an OpenShift Container Platform 4.8 cluster with oc with an account that has cluster-admin permissions
#4. To allow the cluster pull the image, the repository where you push your image must be set as public, or you must configure an image pull secret

operator-sdk init \
    --plugins=helm \
    --domain=trilio.io \
    --group=tvo \
    --version=v1 \
    --kind=TVOControlPlane \
    --helm-chart ../../helm-chart/tvo-chart
