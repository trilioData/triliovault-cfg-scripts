#!/bin/bash -x

helm install test1 ./tvo-chart --dry-run --values=./tvo-chart/values_overrides/trilio_inputs_dynamic.yaml --values=./tvo-chart/values_overrides/trilio_inputs.yaml --values=./tvo-chart/values_overrides/trilio_inputs_keystone.yaml > tvo-chart-manifest.yaml

if [ $? -ne 0 ]; then
  echo "Command execution failed. Exiting"
  exit 1
fi

echo -e "Output writen in file tvo-chart-manifest.yaml"
