#!/bin/bash

set -e

buildah bud --pull-always --format=oci -t dmapi:rhosp18-dev1 -f Dockerfile_rhosp18