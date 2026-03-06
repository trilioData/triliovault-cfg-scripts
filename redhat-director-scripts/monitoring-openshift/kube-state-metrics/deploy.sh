#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="openshift-user-workload-monitoring"
APP_LABEL="app.kubernetes.io/name=kube-state-metrics"
DEPLOYMENT_NAME="kube-state-metrics"

echo "=================================================="
echo "Deploying kube-state-metrics"
echo "Namespace: ${NAMESPACE}"
echo "=================================================="

# --------------------------------------------------
# 1. Validate namespace
# --------------------------------------------------
if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: Namespace ${NAMESPACE} does not exist."
  exit 1
fi
echo "Namespace exists"

# --------------------------------------------------
# 2. Validate ServiceMonitor CRD
# --------------------------------------------------
if ! oc get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "ERROR: ServiceMonitor CRD not found. Is user workload monitoring enabled?"
  exit 1
fi
echo "ServiceMonitor CRD exists"

# --------------------------------------------------
# 3. Apply manifests
# --------------------------------------------------
echo "Applying manifests..."
oc apply -f kube-state-metrics-rbac.yaml
oc apply -f kube-state-metrics-deployment.yaml
oc apply -f kube-state-metrics-service.yaml
oc apply -f kube-state-metrics-servicemonitor.yaml

# --------------------------------------------------
# 4. Wait for rollout
# --------------------------------------------------
echo "Waiting for rollout..."
oc rollout status deployment/${DEPLOYMENT_NAME} -n "${NAMESPACE}" --timeout=120s

# --------------------------------------------------
# 5. Validate Pod Ready
# --------------------------------------------------
echo "Validating pod readiness..."
oc wait --for=condition=Ready pod -l ${APP_LABEL} -n "${NAMESPACE}" --timeout=120s
echo "Pod is Ready"

# --------------------------------------------------
# 6. Validate Service exists
# --------------------------------------------------
if ! oc get svc ${DEPLOYMENT_NAME} -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: Service not found."
  exit 1
fi
echo "Service exists"

# --------------------------------------------------
# 7. Validate Endpoints populated
# --------------------------------------------------
ENDPOINTS=$(oc get endpoints ${DEPLOYMENT_NAME} -n "${NAMESPACE}" -o jsonpath='{.subsets[*].addresses[*].ip}' || true)

if [[ -z "${ENDPOINTS}" ]]; then
  echo "ERROR: Service has no endpoints."
  exit 1
fi
echo "Service endpoints registered"

# --------------------------------------------------
# 8. Validate ServiceMonitor exists
# --------------------------------------------------
if ! oc get servicemonitor ${DEPLOYMENT_NAME} -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: ServiceMonitor not found."
  exit 1
fi
echo "ServiceMonitor exists"

# --------------------------------------------------
# 9. Validate metrics endpoint responds
# --------------------------------------------------
# POD=$(oc get pod -l ${APP_LABEL} -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')

# if ! oc exec -n "${NAMESPACE}" ${POD} -- curl -s localhost:8080/metrics >/dev/null 2>&1; then
#   echo "ERROR: Metrics endpoint not responding."
#   exit 1
# fi
# echo "Metrics endpoint responding"

# echo "=================================================="
# echo "kube-state-metrics deployment SUCCESSFUL"
# echo "=================================================="

echo "Pod:"
oc get pods -n "${NAMESPACE}" -l ${APP_LABEL}

echo "ServiceMonitor:"
oc get servicemonitor -n "${NAMESPACE}" ${DEPLOYMENT_NAME}
