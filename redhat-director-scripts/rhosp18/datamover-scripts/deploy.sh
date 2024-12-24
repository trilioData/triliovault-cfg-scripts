#!/bin/bash -x

set -e

oc apply -f cm-trilio-datamover.yaml
oc apply -f trilio-datamover-service.yaml
