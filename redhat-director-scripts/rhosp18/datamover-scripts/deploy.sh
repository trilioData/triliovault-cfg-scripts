#!/bin/bash -x

set -e

oc apply -f cm_trilio_datamover.yaml
oc apply -f trilio-datamover-service.yaml
