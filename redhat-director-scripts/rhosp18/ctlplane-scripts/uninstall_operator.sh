#!/bin/bash -x

if [ $# -lt 1 ];then
   echo "Script takes exactly 1 argument"
   echo -e "./uninstall_operator.sh <TVO_OPERATOR_FULL_IMAGE_URL>"
   exit 1
fi

TVO_OPERATOR_IMAGE_URL=$1
## Install CRD
cd operator/tvo-operator/
make install

## Install Operator
export IMG=${TVO_OPERATOR_IMAGE_URL}
make undeploy IMG=$IMG
