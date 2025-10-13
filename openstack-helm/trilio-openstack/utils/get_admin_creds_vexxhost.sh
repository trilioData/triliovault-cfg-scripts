#!/bin/bash -x

set -e

if [ $# -lt 2 ];then
   echo "Script takes exacyly 2 arguments"
   echo -e "./get_admin_creds_vexxhost.sh <internal_domain_name> <public_domain_name>"
   echo -e "./get_admin_creds_vexxhost.sh cluster.local company.public.net"
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
MYSQL_DBADMIN_PASSWORD=$(kubectl -n openstack get secrets/internal-percona-xtradb --template={{.data.root}} | base64 -d)

## Trilio Rabbitmq 
TRILIO_RABBITMQ_ADMIN_PASSWORD=$(kubectl -n trilio-openstack get secret/rabbitmq-default-user --template={{.data.password}} | base64 -d)
TRILIO_RABBITMQ_ADMIN_USERNAME=$(kubectl -n trilio-openstack get secret/rabbitmq-default-user --template={{.data.username}} | base64 -d)

## Create nova compute related conf file
kubectl -n openstack get secret/nova-etc -o "jsonpath={.data['nova-compute\.conf']}" | base64 -d > ../templates/bin/_triliovault-nova-compute.conf.tpl
./sync_nova_compute.sh

CRT=$(kubectl -n cert-manager get secrets/cert-manager-selfsigned-ca -o "jsonpath={.data['tls\.crt']}" | base64 -d | sed 's/^[ \t]*//' | sed 's/^/            /')
KEY=$(kubectl -n cert-manager get secrets/cert-manager-selfsigned-ca -o "jsonpath={.data['tls\.key']}" | base64 -d | awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}')
CA=$(kubectl -n cert-manager get secrets/cert-manager-selfsigned-ca -o "jsonpath={.data['ca\.crt']}" | base64 -d | sed 's/^[ \t]*//' | sed 's/^/            /')
cd ../

tee > values_overrides/admin_creds.yaml  << EOF

conf:
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
    host_fqdn_override:
      default:
        host: rabbitmq.trilio-openstack.svc.$INTERNAL_DOMAIN_NAME
  oslo_messaging_datamover:
    auth:
      admin:
        username: $TRILIO_RABBITMQ_ADMIN_USERNAME
        password: $TRILIO_RABBITMQ_ADMIN_PASSWORD
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
        host: percona-xtradb-haproxy.openstack.svc.$INTERNAL_DOMAIN_NAME
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
        host: percona-xtradb-haproxy.openstack.svc.$INTERNAL_DOMAIN_NAME
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
