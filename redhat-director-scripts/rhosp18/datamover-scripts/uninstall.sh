#!/bin/bash -x

set -e

oc delete -f cm_trilio_datamover.yaml
oc delete -f trilio-datamover-service.yaml
