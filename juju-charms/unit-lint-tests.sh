#!/bin/bash -ux
# A test script to check and build Trilio charms from this repo
# This is useful for developer iterations.

time ./build.sh | tee results.txt
set -e
egrep "ERROR:| W:| E:" results.txt && exit 1 || exit 0
