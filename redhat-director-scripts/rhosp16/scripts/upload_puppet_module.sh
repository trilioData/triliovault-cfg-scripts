#!/bin/bash

##Source udndercloud credentials
source /home/stack/stackrc

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

rm -rf $SCRIPT_DIR/trilio-puppet-module
mkdir $SCRIPT_DIR/trilio-puppet-module
cp -R $SCRIPT_DIR/../puppet/trilio $SCRIPT_DIR/trilio-puppet-module/
upload-puppet-modules --seconds 630720000 -d trilio-puppet-module
