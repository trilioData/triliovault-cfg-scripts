#!/bin/bash

## Replace placeholder '<PATH_TO_OTHER_PUPPET_MODULE>' with absolute path of other puppet module.

##Source udndercloud credentials
source /home/stack/stackrc

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

rm -rf $SCRIPT_DIR/puppet-modules
mkdir $SCRIPT_DIR/puppet-modules
cp -R $SCRIPT_DIR/../puppet/trilio $SCRIPT_DIR/puppet-modules/
cp -R <PATH_TO_OTHER_PUPPET_MODULE> $SCRIPT_DIR/puppet-modules/
upload-puppet-modules --seconds 630720000 -d puppet-modules
