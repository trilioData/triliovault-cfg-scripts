#!/bin/bash -x

## Install CRD

cd ../operator/tvo-operator/
make install

## Install Operator
export IMG=docker.io/trilio/tvo-operator:dev2
make deploy IMG=$IMG
