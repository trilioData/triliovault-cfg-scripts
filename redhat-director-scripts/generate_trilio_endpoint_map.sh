#!/bin/bash

set -e

if [ $# -lt 1 ];then
   echo "Script takes exacyly 2 argument"
   echo -e "./generate_trilo_endpoint_map.sh <openstack-tripleo-heat-templates location>"
   exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TEMPLATES=$1
THT_ENDPOINT_DATA=$TEMPLATES/network/endpoints/endpoint_data.yaml
TRILIO_ENDPOINT_DATA=$SCRIPT_DIR/trilio_endpoint_data.yaml
OUTPUT_FILE=$SCRIPT_DIR/trilio_endpoint_map.yaml

echo "Generate endpoint map from ${THT_ENDPOINT_DATA} and ${TRILIO_ENDPOINT_DATA}"
$TEMPLATES/network/endpoints/build_endpoint_map.py \
    -i <(cat $THT_ENDPOINT_DATA $TRILIO_ENDPOINT_DATA) \
    -o $OUTPUT_FILE
echo "Wrote ${OUTPUT_FILE}"
