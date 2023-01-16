#!/bin/bash
SCRIPT=`realpath $0`
SCRIPT_DIR=`dirname ${SCRIPT}`

echo ${SCRIPT_DIR}

WLM_API_IMAGE_NAME=${WLM_API_IMAGE_NAME:-"wlm-api-2"}
WLM_CRON_IMAGE_NAME=${WLM_CRON_IMAGE_NAME:-"wlm-cron-2"}
WLM_SCH_IMAGE_NAME=${WLM_SCH_IMAGE_NAME:-"wlm-scheduler-2"}
WLM_WKLOADS_IMAGE_NAME=${WLM_WKLOADS_IMAGE_NAME:-"wlm-workloads-2"}

# Kill existing images
docker kill ${WLM_API_IMAGE_NAME} ${WLM_CRON_IMAGE_NAME} ${WLM_SCH_IMAGE_NAME} ${WLM_WKLOADS_IMAGE_NAME}
docker rm ${WLM_API_IMAGE_NAME} ${WLM_CRON_IMAGE_NAME} ${WLM_SCH_IMAGE_NAME} ${WLM_WKLOADS_IMAGE_NAME}


BASE_NAME=${BASE_NAME:-"trilio"}
TVO_RELEASE_VERSION=${TVO_RELEASE_VERSION:-"dev1"}
OPENSTACK_VERSION=${OPENSTACK_VERSION:-"train"}
DISTRO=${DISTRO:-"ubuntu"}
DISTRO_RELEASE=${DISTRO_RELEASE:-"bionic"}

# Formulated Tag name
BUILD_IMAGE_TAG=${BUILD_IMAGE_TAG:-"${TVO_RELEASE_VERSION}-${OPENSTACK_VERSION}-${DISTRO}_${DISTRO_RELEASE}"}
echo ${BUILD_IMAGE_TAG}

# ----------------------------------------------------------------------------

######################
### Pre-requisites ###
######################
# - Copy workloadmgr.conf and api-paste.ini file in the current directory

# ----------------------------------------------------------------------------
PACKAGE_DIR=${PACKAGE_DIR:-"triliovault-wlm"}

# NOTE:
# - Mounting required files i.e. workloadmgr.conf and api-paste.ini
#   to both the location inside the containers to suppport the hardcoded
#   locations inside the code

# Run wlm-api image
#docker run -d -v /root/code/tvo-automation/docker-images/openstack-helm/trilliodata-wlm/test/workloadmgr.conf:/etc/workloadmgr/workloadmgr.conf:ro -v /root/code/tvo-automation/docker-images/openstack-helm/trilliodata-wlm/test/api-paste.ini:/etc/workloadmgr/api-paste.ini:ro --privileged=true --network host --entrypoint "workloadmgr-api --config-file=/etc/workloadmgr/workloadmgr.conf" --name ${WLM_API_IMAGE_NAME} triliovault/triliovault-wlm:5.0-victoria-ubuntu_focal
docker run -d \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/workloadmgr/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/${PACKAGE_DIR}/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/workloadmgr/api-paste.ini:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/${PACKAGE_DIR}/api-paste.ini:ro \
    --privileged=true \
    --network host \
    --name ${WLM_API_IMAGE_NAME} \
    ${BASE_NAME}/triliovault-wlm-helm:${BUILD_IMAGE_TAG} \
    /usr/bin/workloadmgr-api --config-file=/etc/${PACKAGE_DIR}/workloadmgr.conf

# Run wlm-cron image
docker run -d \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/workloadmgr/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/${PACKAGE_DIR}/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/workloadmgr/api-paste.ini:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/${PACKAGE_DIR}/api-paste.ini:ro \
    --privileged=true \
    --network host \
    --name ${WLM_CRON_IMAGE_NAME} \
    ${BASE_NAME}/triliovault-wlm-helm:${BUILD_IMAGE_TAG} \
    /usr/bin/workloadmgr-cron --config-file=/etc/${PACKAGE_DIR}/workloadmgr.conf


# Run wlm-scheduler image
docker run -d \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/workloadmgr/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/${PACKAGE_DIR}/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/workloadmgr/api-paste.ini:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/${PACKAGE_DIR}/api-paste.ini:ro \
    --privileged=true \
    --network host \
    --name ${WLM_SCH_IMAGE_NAME} \
    ${BASE_NAME}/triliovault-wlm-helm:${BUILD_IMAGE_TAG} \
    /usr/bin/workloadmgr-scheduler --config-file=/etc/${PACKAGE_DIR}/workloadmgr.conf


# Run wlm-workloads image
docker run -d \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/workloadmgr/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/workloadmgr.conf:/etc/${PACKAGE_DIR}/workloadmgr.conf:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/workloadmgr/api-paste.ini:ro \
    -v ${SCRIPT_DIR}/api-paste.ini:/etc/${PACKAGE_DIR}/api-paste.ini:ro \
    --privileged=true \
    --network host \
    --name ${WLM_WKLOADS_IMAGE_NAME} \
    ${BASE_NAME}/triliovault-wlm-helm:${BUILD_IMAGE_TAG} \
    /usr/bin/workloadmgr-workloads --config-file=/etc/${PACKAGE_DIR}/workloadmgr.conf
