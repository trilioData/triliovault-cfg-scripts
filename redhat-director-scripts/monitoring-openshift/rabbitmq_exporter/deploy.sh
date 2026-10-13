#!/usr/bin/env bash
# Deploys rabbitmq-exporter for Trilio vhost monitoring.
#
# Prerequisites:
#   1. Create the credentials secret before running this script:
#
#      # On RHOSO 18 Trilio uses a dedicated cluster in trilio-openstack:
#      export RABBITMQ_HOST="trilio-rabbitmq-cluster.trilio-openstack.svc"
#      export RABBITMQ_MONITORING_USER="<management-api-user>"
#      export RABBITMQ_MONITORING_PASSWORD="<management-api-password>"
#      envsubst < rabbitmq-exporter-secret.yaml | oc apply -f -
#
#      Retrieve the default admin credentials with:
#        oc get secret trilio-rabbitmq-cluster-default-user -n trilio-openstack -o yaml

set -euo pipefail

NAMESPACE="trilio-monitoring"
DEPLOYMENT_NAME="rabbitmq-exporter"
APP_LABEL="app=rabbitmq-exporter"

echo "=================================================="
echo "Deploying rabbitmq-exporter (Trilio queue monitoring)"
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
# 3. Validate secret exists
# --------------------------------------------------
if ! oc get secret rabbitmq-exporter-secret -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: Secret 'rabbitmq-exporter-secret' not found in ${NAMESPACE}."
  echo "       Create it first — see the Prerequisites comment at the top of this script."
  exit 1
fi
echo "Secret exists"

# --------------------------------------------------
# 4. Apply manifests
# --------------------------------------------------
echo "Applying manifests..."
oc apply -f rabbitmq-exporter-deployment.yaml
oc apply -f rabbitmq-exporter-service.yaml
oc apply -f rabbitmq-exporter-servicemonitor.yaml
oc apply -f rabbitmq-exporter-route.yaml

# --------------------------------------------------
# 5. Wait for rollout
# --------------------------------------------------
echo "Waiting for rollout..."
oc rollout status deployment/${DEPLOYMENT_NAME} -n "${NAMESPACE}" --timeout=120s

# --------------------------------------------------
# 6. Validate pod ready
# --------------------------------------------------
echo "Validating pod readiness..."
oc wait --for=condition=Ready pod -l ${APP_LABEL} -n "${NAMESPACE}" --timeout=120s
echo "Pod is Ready"

# --------------------------------------------------
# 7. Validate service endpoints populated
# --------------------------------------------------
ENDPOINTS=$(oc get endpoints ${DEPLOYMENT_NAME} -n "${NAMESPACE}" \
  -o jsonpath='{.subsets[*].addresses[*].ip}' || true)
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

echo ""
echo "Pod:"
oc get pods -n "${NAMESPACE}" -l ${APP_LABEL}

echo ""
echo "ServiceMonitor:"
oc get servicemonitor -n "${NAMESPACE}" ${DEPLOYMENT_NAME}

echo ""
echo "=================================================="
echo "rabbitmq-exporter deployment SUCCESSFUL"
echo "Vhosts monitored: workloadmgr, dmapi"
echo "Metrics port: 9419"
echo "=================================================="
