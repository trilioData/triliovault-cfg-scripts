#!/usr/bin/env bash
# Removes all rabbitmq-exporter resources from trilio-monitoring.
# Safe to run even if some resources do not exist.

set -euo pipefail

NAMESPACE="trilio-monitoring"
NAME="rabbitmq-exporter"

echo "=================================================="
echo "Tearing down rabbitmq-exporter"
echo "Namespace: ${NAMESPACE}"
echo "=================================================="

oc delete servicemonitor ${NAME} -n "${NAMESPACE}" --ignore-not-found
oc delete route         ${NAME} -n "${NAMESPACE}" --ignore-not-found
oc delete service       ${NAME} -n "${NAMESPACE}" --ignore-not-found
oc delete deployment    ${NAME} -n "${NAMESPACE}" --ignore-not-found
oc delete secret        rabbitmq-exporter-secret -n "${NAMESPACE}" --ignore-not-found

echo "Teardown complete."
