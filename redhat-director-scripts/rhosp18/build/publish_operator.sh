#!/bin/bash

export IMG=docker.io/trilio/tvo-operator:dev-shyam-1
make docker-push IMG=$IMG