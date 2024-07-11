#!/bin/bash -x
cd ../../


helm upgrade --install tvo-chart ./tvo-chart --dry-run --namespace=triliovault \
--values=./tvo-chart/values_overrides/trilio_inputs_dynamic.yaml \
--values=./tvo-chart/values_overrides/trilio_inputs.yaml 


kubectl get pods
