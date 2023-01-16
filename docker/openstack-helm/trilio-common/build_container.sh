#!/bin/bash -x

set -e
TAG="5.0.5-victoria-ubuntu_focal"

docker build --no-cache -t trilio/trilio-common:${TAG} -f Dockerfile_victoria_ubuntu_focal .
