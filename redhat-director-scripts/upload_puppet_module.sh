#!/bin/bash

##Source udndercloud credentials
source /home/stack/stackrc


rm -rf trilio-puppet-module
mkdir trilio-puppet-module
cp -R puppet/trilio trilio-puppet-module/
upload-puppet-modules -d trilio-puppet-module
