#!/bin/bash
FILE=input_values.txt
source input_values.txt
ENV_FILE=admin_openrc
#declare -a OS_ENV_ARRAY
if test -f "input_values.txt"; then
   if test -f $ENV_FILE; then rm -f $ENV_FILE; fi
    echo "$FILE exists."
    while IFS='=' read -r key value
    do
       key=$(echo $key  )
       eval ${key}=\${value}
       echo $key=$value
       case $key  in
          CLOUD_ADMIN_KEYSTONE_AUTH_URL)
             #OS_ENV_ARRAY[OS_AUTH_URL]=$value
	     echo export OS_AUTH_URL="$value" >> $ENV_FILE
          ;;
          CLOUD_ADMIN_USER_NAME)
             #OS_ENV_ARRAY[OS_USERNAME]=$value
	     echo export OS_USERNAME=$value >> $ENV_FILE
          ;;
          CLOUD_ADMIN_USER_PASSWORD)
             #OS_ENV_ARRAY[OS_PASSWORD]=$value
	     echo export OS_PASSWORD=$value >> $ENV_FILE
          ;;
          CLOUD_ADMIN_PROJECT_NAME)
            #OS_ENV_ARRAY[OS_PROJECT_NAME]=$value
	    echo export OS_PROJECT_NAME=$value >> $ENV_FILE
          ;;
          CLOUD_ADMIN_PROJECT_ID)
            #OS_ENV_ARRAY[OS_PROJECT_ID]=$value
	    echo export OS_PROJECT_ID=$value >> $ENV_FILE
          ;;
          CLOUD_ADMIN_DOMAIN_NAME)
            #OS_ENV_ARRAY[OS_USER_DOMAIN_NAME]=$value
	    echo export OS_USER_DOMAIN_NAME=$value >> $ENV_FILE
	    echo export OS_REGION_NAME="USEAST" >> $ENV_FILE
	    echo export OS_INTERFACE="public" >> $ENV_FILE
	    echo export OS_IDENTITY_API_VERSION=3  >> $ENV_FILE
          ;;
         *)
          echo "Unknown Value...."
          ;;
      esac
    done < "$FILE"

fi 

. ./$ENV_FILE

echo "Fetching variables for the triliovault-wlm-dynamic-values.conf"

CLOUD_ADMIN_USER_ID=$(openstack user show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id  "${CLOUD_ADMIN_USER_NAME}") 

CLOUD_ADMIN_DOMAIN_ID=$(openstack domain show -f value -c id "${CLOUD_ADMIN_DOMAIN_NAME}")

CLOUD_ADMIN_PROJECT_ID=$(openstack project show -f value -c id  "${CLOUD_ADMIN_PROJECT_NAME}")

WLM_PROJECT_DOMAIN_ID=$(openstack project show -f value -c domain_id  "${WLM_PROJECT_DOMAIN_NAME}")

WLM_USER_ID=$(openstack user show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c id "${WLM_USER_NAME}")

WLM_USER_DOMAIN_ID=$(openstack user show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c domain_id  "${WLM_USER_NAME}")

tee > /etc/triliovault-wlm/triliovault-wlm-dynamic-values.conf << EOF

[DEFAULT]
cloud_admin_user_id = $CLOUD_ADMIN_USER_ID
cloud_admin_project_id = $CLOUD_ADMIN_PROJECT_ID
cloud_admin_domain = $CLOUD_ADMIN_DOMAIN_ID
cloud_unique_id = $WLM_USER_ID
triliovault_user_domain_id = $WLM_USER_DOMAIN_ID
domain_name = $CLOUD_ADMIN_DOMAIN_ID

[keystone_authtoken]
project_domain_id = $WLM_PROJECT_DOMAIN_ID
user_domain_id = $WLM_USER_DOMAIN_ID
EOF

