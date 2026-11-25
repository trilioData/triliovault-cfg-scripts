#!/bin/bash -x

# TVO operator pod CPU/memory requests and limits (optional).
# Uncomment and set to override. Values left commented use the defaults shown, for new deployments and upgrades.
# On upgrade (re-running this script with a new image), set any custom values again, otherwise the defaults apply.
#TVO_OPERATOR_CPU_REQUEST="100m"
#TVO_OPERATOR_MEMORY_REQUEST="512Mi"
#TVO_OPERATOR_CPU_LIMIT="1"
#TVO_OPERATOR_MEMORY_LIMIT="2Gi"

## Install CRD
if [ $# -lt 1 ];then
   echo "Script takes exactly 1 argument"
   echo -e "./install_operator.sh <TVO_OPERATOR_CONTAINER_IMAGE_URL>"
   exit 1
fi

IMAGE_TAG=$1

cd operator/tvo-operator/
make install

## Install Operator
export IMG=${IMAGE_TAG}
make deploy IMG=$IMG

oc -n tvo-operator-system set resources deployment/tvo-operator-controller-manager -c manager \
   --requests=cpu=${TVO_OPERATOR_CPU_REQUEST:-100m},memory=${TVO_OPERATOR_MEMORY_REQUEST:-512Mi} \
   --limits=cpu=${TVO_OPERATOR_CPU_LIMIT:-1},memory=${TVO_OPERATOR_MEMORY_LIMIT:-2Gi}
