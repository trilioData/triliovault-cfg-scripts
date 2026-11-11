#!/bin/bash -x

set -e

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 arguments"
   echo -e "./get_admin_creds.sh <internal_domain_name> <public_domain_name>"
   echo -e "./get_admin_creds.sh cluster.local company.public.net"
   exit 1
fi

INTERNAL_DOMAIN_NAME=$1
PUBLIC_DOMAIN_NAME=$2

## Keystone creds
OS_AUTH_URL=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_AUTH_URL}} | base64 -d)
OS_DEFAULT_DOMAIN=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_DEFAULT_DOMAIN}} | base64 -d)
OS_INTERFACE=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_INTERFACE}} | base64 -d)
OS_PASSWORD=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_PASSWORD}} | base64 -d)
OS_PROJECT_DOMAIN_NAME=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_PROJECT_DOMAIN_NAME}} | base64 -d)
OS_PROJECT_NAME=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_PROJECT_NAME}} | base64 -d)
OS_REGION_NAME=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_REGION_NAME}} | base64 -d)
OS_USER_DOMAIN_NAME=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_USER_DOMAIN_NAME}} | base64 -d)
OS_USERNAME=$(kubectl -n openstack get secrets/nova-keystone-admin --template={{.data.OS_USERNAME}} | base64 -d)

## DB creds
MYSQL_DBADMIN_PASSWORD=$(kubectl -n openstack get secrets/mariadb-dbadmin-password --template={{.data.MYSQL_DBADMIN_PASSWORD}} | base64 -d)

## Trilio Rabbitmq 
TRILIO_RABBITMQ_ADMIN_PASSWORD=$(kubectl -n trilio-openstack get secret/rabbitmq-default-user --template={{.data.password}} | base64 -d)
TRILIO_RABBITMQ_ADMIN_USERNAME=$(kubectl -n trilio-openstack get secret/rabbitmq-default-user --template={{.data.username}} | base64 -d)

## Create nova compute related conf file
kubectl -n openstack get secret/nova-etc -o "jsonpath={.data['nova-compute\.conf']}" | base64 -d > ../templates/bin/_triliovault-nova-compute.conf.tpl
## OpenStack-Helm 2026.1+: nova-compute.conf no longer carries the service credentials
## ([placement], [neutron], [cinder], [keystone_authtoken], [service_user]); nova-compute loads them
## from secret nova-ks-etc via --config-dir. Without them the datamover can't authenticate to
## Placement and exits 0 (pod shows "Completed"). Append them; oslo.config merges a section that
## appears more than once. Older releases have no nova-ks-etc, so nothing changes there.
if kubectl -n openstack get secret/nova-ks-etc >/dev/null 2>&1; then
   echo "Found secret openstack/nova-ks-etc: appending nova service credentials to nova-compute.conf"
   kubectl -n openstack get secret/nova-ks-etc -o go-template='{{range $k, $v := .data}}{{"\n"}}{{$v | base64decode}}{{end}}' >> ../templates/bin/_triliovault-nova-compute.conf.tpl
fi
./sync_nova_compute.sh

{ set +x; } 2>/dev/null
LIBVIRT_TLS_CLIENT_SECRET=${LIBVIRT_TLS_CLIENT_SECRET:-libvirt-tls-client}
LIBVIRT_TLS_SERVER_SECRET=${LIBVIRT_TLS_SERVER_SECRET:-libvirt-tls-server}
LIBVIRT_TLS_ENABLED=false
LIBVIRT_CA=""
LIBVIRT_CLIENT_CERT=""
LIBVIRT_CLIENT_KEY=""
if kubectl -n openstack get secret/nova-etc -o go-template='{{range $k, $v := .data}}{{$v | base64decode}}{{"\n"}}{{end}}' | grep -q 'qemu+tls://'; then
   if ! kubectl -n openstack get secret/$LIBVIRT_TLS_CLIENT_SECRET >/dev/null 2>&1; then
      echo "ERROR: nova connects to libvirt over qemu+tls but secret openstack/$LIBVIRT_TLS_CLIENT_SECRET was not found. Set LIBVIRT_TLS_CLIENT_SECRET to the libvirt client certificate secret name."
      exit 1
   fi
   echo "Libvirt TLS is enabled: datamover will use the libvirt client certificate from secret openstack/$LIBVIRT_TLS_CLIENT_SECRET"
   LIBVIRT_TLS_ENABLED=true
   LIBVIRT_CA=$(kubectl -n openstack get secret/$LIBVIRT_TLS_CLIENT_SECRET -o "jsonpath={.data['cacert\.pem']}" | base64 -d)
   if [ -z "$LIBVIRT_CA" ]; then
      LIBVIRT_CA=$(kubectl -n openstack get secret/$LIBVIRT_TLS_SERVER_SECRET -o "jsonpath={.data['cacert\.pem']}" | base64 -d)
   fi
   LIBVIRT_CLIENT_CERT=$(kubectl -n openstack get secret/$LIBVIRT_TLS_CLIENT_SECRET -o "jsonpath={.data['clientcert\.pem']}" | base64 -d)
   LIBVIRT_CLIENT_KEY=$(kubectl -n openstack get secret/$LIBVIRT_TLS_CLIENT_SECRET -o "jsonpath={.data['clientkey\.pem']}" | base64 -d)
   if [ -z "$LIBVIRT_CA" ] || [ -z "$LIBVIRT_CLIENT_CERT" ] || [ -z "$LIBVIRT_CLIENT_KEY" ]; then
      echo "ERROR: cacert.pem, clientcert.pem or clientkey.pem is missing in secrets openstack/$LIBVIRT_TLS_CLIENT_SECRET and openstack/$LIBVIRT_TLS_SERVER_SECRET"
      exit 1
   fi
fi
LIBVIRT_CA=$(echo "$LIBVIRT_CA" | sed 's/^/        /')
LIBVIRT_CLIENT_CERT=$(echo "$LIBVIRT_CLIENT_CERT" | sed 's/^/        /')
LIBVIRT_CLIENT_KEY=$(echo "$LIBVIRT_CLIENT_KEY" | sed 's/^/        /')
set -x

CRT=$(kubectl -n openstack get secrets/keystone-tls-public -o "jsonpath={.data['tls\.crt']}" | base64 -d | sed 's/^[ \t]*//' | sed 's/^/            /')
KEY=$(kubectl -n openstack get secrets/keystone-tls-public -o "jsonpath={.data['tls\.key']}" | base64 -d | awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}')
CA=$(kubectl -n openstack get secrets/trilio-ca-cert -o "jsonpath={.data['ca\.crt']}" | base64 -d | sed 's/^[ \t]*//' | sed 's/^/            /') 
cd ../

tee > values_overrides/admin_creds.yaml  << EOF

conf:
  triliovault:
    libvirt_tls:
      enabled: $LIBVIRT_TLS_ENABLED
      source: secret
      ca_cert: |
$LIBVIRT_CA
      client_cert: |
$LIBVIRT_CLIENT_CERT
      client_key: |
$LIBVIRT_CLIENT_KEY
  wlm: 
    keystone_authtoken:
      memcached_servers: memcached.openstack.svc.$INTERNAL_DOMAIN_NAME:11211
endpoints:
  identity:
    name: keystone
    auth:
      admin:
        region_name: $OS_REGION_NAME
        username: $OS_USERNAME
        password: $OS_PASSWORD
        project_name: $OS_PROJECT_NAME
        user_domain_name: $OS_USER_DOMAIN_NAME
        project_domain_name: $OS_PROJECT_DOMAIN_NAME
    host_fqdn_override:
      default:
        host: keystone-api.openstack.svc.$INTERNAL_DOMAIN_NAME
      internal:
        host: keystone-api.openstack.svc.$INTERNAL_DOMAIN_NAME
      public:
        host: keystone.$PUBLIC_DOMAIN_NAME
  oslo_messaging_wlm:
    auth:
      admin:
        username: $TRILIO_RABBITMQ_ADMIN_USERNAME
        password: $TRILIO_RABBITMQ_ADMIN_PASSWORD
        secret:
          tls:
            internal: rabbitmq-tls-direct
    host_fqdn_override:
      default:
        host: rabbitmq.trilio-openstack.svc.$INTERNAL_DOMAIN_NAME
  oslo_messaging_datamover:
    auth:
      admin:
        username: $TRILIO_RABBITMQ_ADMIN_USERNAME
        password: $TRILIO_RABBITMQ_ADMIN_PASSWORD
        secret:
          tls:
            internal: rabbitmq-tls-direct
    host_fqdn_override:
      default:
        host: rabbitmq.trilio-openstack.svc.$INTERNAL_DOMAIN_NAME
  oslo_db_triliovault_datamover:
    auth:
      admin:
        username: root
        password: $MYSQL_DBADMIN_PASSWORD
        secret:
          tls:
            internal: mariadb-tls-direct
    host_fqdn_override:
      default:
        host: mariadb.openstack.svc.$INTERNAL_DOMAIN_NAME
  oslo_db_triliovault_wlm:
    auth:
      admin:
        username: root
        password: $MYSQL_DBADMIN_PASSWORD
        secret:
          tls:
            internal: mariadb-tls-direct
    host_fqdn_override:
      default:
        host: mariadb.openstack.svc.$INTERNAL_DOMAIN_NAME
  datamover:
    host_fqdn_override:
      default:
        host: triliovault-datamover-api.trilio-openstack.svc.$INTERNAL_DOMAIN_NAME
      public:
        host: triliovault-datamover.$PUBLIC_DOMAIN_NAME
        tls:
          crt: |
$CRT
          key: "$KEY"
          ca: |
$CA
  workloads:
    host_fqdn_override:
      default:
        host: triliovault-wlm-api.trilio-openstack.svc.$INTERNAL_DOMAIN_NAME
      public:
        host: triliovault-wlm.$PUBLIC_DOMAIN_NAME
        tls:
          crt: |
$CRT
          key: "$KEY"
          ca: |
$CA
  image:
    host_fqdn_override:
      default:
        host: glance-api.openstack.svc.$INTERNAL_DOMAIN_NAME
      public:
        host: glance.$PUBLIC_DOMAIN_NAME
  network:
    host_fqdn_override:
      default:
        host: neutron-server.openstack.svc.$INTERNAL_DOMAIN_NAME
      public:
        host: neutron.$PUBLIC_DOMAIN_NAME
  compute:
    host_fqdn_override:
      default:
        host: nova-api.openstack.svc.$INTERNAL_DOMAIN_NAME
      public:
        host: nova.$PUBLIC_DOMAIN_NAME
  volumev3:
    host_fqdn_override:
      default:
        host: cinder-api.openstack.svc.$INTERNAL_DOMAIN_NAME
      public:
        host: cinder.$PUBLIC_DOMAIN_NAME
  oslo_cache:
    host_fqdn_override:
      default:
        host: memcached.openstack.svc.$INTERNAL_DOMAIN_NAME
EOF


echo "Output written to ../values_overrides/admin_creds.yaml"
