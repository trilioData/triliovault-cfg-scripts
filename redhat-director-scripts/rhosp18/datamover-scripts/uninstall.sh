#!/bin/bash -x

set -e

oc delete -f cm-trilio-datamover.yaml
oc delete -f trilio-datamover-service.yaml
