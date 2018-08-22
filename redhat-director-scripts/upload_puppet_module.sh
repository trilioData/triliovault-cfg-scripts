#!/bin/bash -x

mkdir puppet-modules

cp -R puppet/trilio puppet-modules/

upload-puppet-modules -d puppet-modules
