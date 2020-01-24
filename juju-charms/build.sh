#!/bin/bash -ux
# A quick and dirty script to build/re-build charms in this repo

# Remove previous builds, if any
if [[ -d builds ]]; then
   rm -rf builds
fi
mkdir -vp builds

# Check and build all of the src reactive charms
for t in pep8 py3 build; do
  for i in $(ls -d1 charm-*); do
    if [[ -d $i/build/ ]]; then
        rm -rf $i/build/
    fi
    (
        cd $i
        if [[ -d .tox/ ]]; then
            rm -rf .tox/
        fi
        tox -e $t
    )
    # Collect the built charms
    mv $i/build/builds/* builds/
  done
done


# Check charm proof on the built charms
for i in $(ls -1 builds/); do
    (
        set +e
        cd builds/$i
#        charm proof
        tox -e pep8
    )
done
