#!/bin/bash -x


helm upgrade --install triliovault-openstack-chart ./tvo-chart --namespace=triliovault \
--values=./tvo-chart/values_overrides/trilio_inputs_dynamic.yaml \
--values=./tvo-chart/values_overrides/trilio_inputs.yaml \
--values=./tvo-chart/values_overrides/trilio_inputs_keystone.yaml


kubectl get pods
