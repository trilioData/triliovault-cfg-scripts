#!/bin/bash -x

set -e

TAG="5.0.5-victoria-ubuntu_focal"

docker tag trilio/trilio-common:${TAG} docker.io/trilio/trilio-common:${TAG}

docker push docker.io/trilio/trilio-common:${TAG}
