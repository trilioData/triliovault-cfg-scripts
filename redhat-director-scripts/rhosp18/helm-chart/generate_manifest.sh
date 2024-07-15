#!/bin/bash -x

helm install test ./tvo-chart --dry-run --values=./tvo-chart/values_overrides/trilio_inputs_dynamic.yaml --values=./tvo-chart/values_overrides/trilio_inputs.yaml > tvo-chart-manifest.yaml
