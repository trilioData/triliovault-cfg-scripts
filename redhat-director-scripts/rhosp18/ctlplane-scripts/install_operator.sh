#!/bin/bash -x

# TVO operator pod CPU/memory requests and limits (optional).
# To override a value, uncomment its line and set it. Any value left commented uses the default:
#   - New deployment: requests cpu 100m, memory 512Mi; limits cpu 1, memory 2Gi.
#   - Upgrade (re-running this script with a new image): values set on an earlier run are kept,
#     values never set use the defaults above.
#   - Set TVO_OPERATOR_RESOURCES_RESET="true" to drop values set earlier and go back to the defaults.
#TVO_OPERATOR_CPU_REQUEST="100m"
#TVO_OPERATOR_MEMORY_REQUEST="512Mi"
#TVO_OPERATOR_CPU_LIMIT="1"
#TVO_OPERATOR_MEMORY_LIMIT="2Gi"
#TVO_OPERATOR_RESOURCES_RESET="false"

## Install CRD
if [ $# -lt 1 ];then
   echo "Script takes exactly 1 argument"
   echo -e "./install_operator.sh <TVO_OPERATOR_CONTAINER_IMAGE_URL>"
   exit 1
fi

IMAGE_TAG=$1

OPERATOR_NAMESPACE=tvo-operator-system
OPERATOR_DEPLOYMENT=tvo-operator-controller-manager
RESOURCES_PATCH=config/manager/resources_patch.yaml

saved_resource() {
   if [ "${TVO_OPERATOR_RESOURCES_RESET:-false}" = "true" ]; then
      return
   fi
   oc -n $OPERATOR_NAMESPACE get deployment $OPERATOR_DEPLOYMENT \
      -o "jsonpath={.metadata.annotations.tvo\.trilio\.io/operator-$1}" 2>/dev/null
}

current_resources() {
   oc -n $OPERATOR_NAMESPACE get deployment $OPERATOR_DEPLOYMENT \
      -o 'jsonpath={.spec.template.spec.containers[?(@.name=="manager")].resources}' 2>/dev/null
   echo
}

CPU_REQUEST=${TVO_OPERATOR_CPU_REQUEST:-$(saved_resource cpu-request)}
MEMORY_REQUEST=${TVO_OPERATOR_MEMORY_REQUEST:-$(saved_resource memory-request)}
CPU_LIMIT=${TVO_OPERATOR_CPU_LIMIT:-$(saved_resource cpu-limit)}
MEMORY_LIMIT=${TVO_OPERATOR_MEMORY_LIMIT:-$(saved_resource memory-limit)}

ANNOTATIONS=""
REQUESTS=""
LIMITS=""

add_resource() {
   local value=$1 annotation=$2 section=$3 key=$4
   if [ -z "$value" ]; then
      return
   fi
   if ! [[ "$value" =~ ^[0-9]+(\.[0-9]+)?(m|k|M|G|T|Ki|Mi|Gi|Ti)?$ ]]; then
      echo "ERROR: invalid value '$value' for TVO operator $annotation"
      exit 1
   fi
   ANNOTATIONS+="    tvo.trilio.io/operator-${annotation}: \"${value}\""$'\n'
   if [ "$section" = "requests" ]; then
      REQUESTS+="            ${key}: \"${value}\""$'\n'
   else
      LIMITS+="            ${key}: \"${value}\""$'\n'
   fi
}

add_resource "$CPU_REQUEST" cpu-request requests cpu
add_resource "$MEMORY_REQUEST" memory-request requests memory
add_resource "$CPU_LIMIT" cpu-limit limits cpu
add_resource "$MEMORY_LIMIT" memory-limit limits memory

echo "TVO operator resources before deploy: $(current_resources)"

cd operator/tvo-operator/

{
   echo "apiVersion: apps/v1"
   echo "kind: Deployment"
   echo "metadata:"
   echo "  name: controller-manager"
   echo "  namespace: system"
   if [ -n "$ANNOTATIONS" ]; then
      echo "  annotations:"
      printf '%s' "$ANNOTATIONS"
   fi
   if [ -n "$REQUESTS$LIMITS" ]; then
      echo "spec:"
      echo "  template:"
      echo "    spec:"
      echo "      containers:"
      echo "      - name: manager"
      echo "        resources:"
      if [ -n "$REQUESTS" ]; then
         echo "          requests:"
         printf '%s' "$REQUESTS"
      fi
      if [ -n "$LIMITS" ]; then
         echo "          limits:"
         printf '%s' "$LIMITS"
      fi
   fi
} > $RESOURCES_PATCH

make install

## Install Operator
export IMG=${IMAGE_TAG}
make deploy IMG=$IMG

echo "TVO operator resources after deploy: $(current_resources)"
