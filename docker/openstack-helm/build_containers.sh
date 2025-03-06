#!/bin/bash -x

set -e

if [ $# -lt 4 ];then
   echo "Script takes exactly 4 arguments"
   echo -e "./build_container.sh <tvault_version> <openstack_releases> <fury_repo> <containers_to_build>"
   exit 1
fi

TVO_RELEASE_VERSION=${TVO_RELEASE_VERSION:-"$(echo $1)"}
fury_repo=$(echo $3)
declare -a openstack_releases=($(echo $2))
declare -a containers_to_build=($(echo $4))
openstack_platform="ubuntu"

current_dir=$(pwd)
base_dir="$(dirname $0)"

if [ $base_dir = '.' ]
then
base_dir="$current_dir"
fi

# Build Variables
# Tag Naming convention for openstack helm
# docker.io/trilliovault/<IMAGE-NAME>:<TVO-RELEASE-VERSION>-<OPENSTACK-VERSION>-<DISTRO>_<DISTRO-RELEASE>
REGISTRY_URI=${REGISTRY_URI:-"docker.io"}
BASE_NAME=${BASE_NAME:-"trilio"}
IMAGE_VERSION=${IMAGE_VERSION:-"latest"}


##
# ==========================================================
# Define the OPTIONAL build variables before execution
# ==========================================================
##

nova_uid=${nova_uid:-"42424"}
nova_gid=${nova_gid:-"42424"}
python_version=${python_version:-"3.8"}

##
# ==========================================================
##


# Ensure BASE_NAME does not ends with /
if [[ "${BASE_NAME}" == */ ]]; then
    echo "BASE_NAME should not end with /."
    exit 1
fi

# Ensure path to registry ends with /
if [[ "${REGISTRY_URI}" != */ ]]; then
    REGISTRY_URI="$REGISTRY_URI/"
fi

#Following function validate_openstack_support kept for future reference. Currently for MOSK (5.0 beta) release, it's calling is NOT required
validate_openstack_support() {
  OPENSTACK_VERSION=$(echo $1)
  DISTRO=$openstack_platform
  DISTRO_RELEASE=$(echo $2)
  # Validation for the support
  BUILD_IMAGE="no"               # Decide whether to build image or not
  CORRECT_VERSION="no"           # Decide whether ubuntu supports a particular openstack version
  SUPPORTED_VERSION="no"         # Decide whether TVO support a version or not
  case ${DISTRO_RELEASE} in
      bionic)
          # Mark the flag to build image
          BUILD_IMAGE="yes"
          case ${OPENSTACK_VERSION} in
              victoria)
                  CORRECT_VERSION="no"
                  SUPPORTED_VERSION="no"
                  ;;
              ussuri)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              train)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="yes"
                  ;;
              stein)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              rocky)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              queens)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              *)
                  CORRECT_VERSION="no"
                  SUPPORTED_VERSION="no"
                  ;;
          esac
          ;;
      focal)
          BUILD_IMAGE="yes"
          case ${OPENSTACK_VERSION} in
              ussuri)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              victoria)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="yes"
                  ;;
              wallaby)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              xena)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              yoga)
                  CORRECT_VERSION="yes"
                  SUPPORTED_VERSION="no"
                  ;;
              *)
                  CORRECT_VERSION="no"
                  SUPPORTED_VERSION="no"
                  ;;
          esac
          ;;
      *)
          BUILD_IMAGE="no"
          ;;
  esac

  if [[ "${BUILD_IMAGE}" == "no" || "${CORRECT_VERSION}" == "no" || "${SUPPORTED_VERSION}" == "no" ]]; then
    echo "Openstack not supported $OPENSTACK_VERSION $DISTRO $DISTRO_RELEASE"
    exit 1
  fi

}

build_container() {
    OPENSTACK_VERSION=$(echo $1)
    DISTRO=$openstack_platform
    CONTAINER=$(echo $2)

    IMAGE_VERSION="latest"
    IMAGE_NAME="$CONTAINER-helm"
    project_dir="$CONTAINER"
    SCRIPT_DIR="$base_dir/$CONTAINER"
    
    cd ${SCRIPT_DIR}
    sed -i "s/{VERSION}/${fury_repo}/g" trilio.list

    # Necesssary build Arguments
    build_args="--force-rm --pull --no-cache"

    # Extra build arguments
    extra_build_args=""
    # - Openstack Repository for the release
    #Commenting as it is hardcoded in required Dockerfiles
    #DISTRO_RELEASE=$(echo $2)
    #extra_build_args="${extra_build_args} --build-arg OPENSTACK_REPO=cloud-archive:${OS_REPO}"
    # - FROM
    #from="docker.io/ubuntu:${DISTRO_RELEASE}"
    #this_from="from"
    #if [[ -n ${!this_from} ]]; then
    #    extra_build_args="${extra_build_args} --build-arg FROM=${!this_from}"
    #fi
    # - NOVA USER_ID
    this_nova_uid="nova_uid"
    if [[ -n ${!this_nova_uid} ]]; then
        extra_build_args="${extra_build_args} --build-arg UID=${!this_nova_uid}"
    fi
    # - NOVA GROUP_ID
    this_nova_gid="nova_gid"
    if [[ -n ${!this_nova_gid} ]]; then
        extra_build_args="${extra_build_args} --build-arg GID=${!this_nova_gid}"
    fi
    # - Project Directory
    this_project_dir="project_dir"
    if [[ -n ${!this_project_dir} ]]; then
        extra_build_args="${extra_build_args} --build-arg PROJECT_DIR=${!this_project_dir}"
    fi
    # - Python Version
    this_python_version="python_version"
    if [[ -n ${!this_python_version} ]]; then
        extra_build_args="${extra_build_args} --build-arg PYTHON_VERSION=${!this_python_version}"
    fi

    # - Fury Repo
    this_fury_repo="fury_repo"
    if [[ -n ${!this_fury_repo} ]]; then
        extra_build_args="${extra_build_args} --build-arg fury_repo=${!this_fury_repo}"
    fi

    # Docker file path
    DOCKER_FILE_PATH="Dockerfile_${OPENSTACK_VERSION}"
    # Formulated Tag name
    BUILD_IMAGE_TAG="${REGISTRY_URI}${BASE_NAME}/${IMAGE_NAME}:${TVO_RELEASE_VERSION}-${OPENSTACK_VERSION}"
    echo "BUILD_IMAGE_TAG : ${BUILD_IMAGE_TAG}"

    if [[ "${OPENSTACK_VERSION}" == "mosk22.5_yoga" && ${container_to_build} != *"horizon"* ]];then
	    echo "For mosk22.5_yoga, copy respective 22.4 Dockerfile against non horizon containers"
	    cp `echo ${DOCKER_FILE_PATH} | sed 's/mosk22.5/mosk22.4/'` ${DOCKER_FILE_PATH}
    fi
    # Build docker image
    echo "Building Project - ${IMAGE_NAME}"
    docker build -t ${BUILD_IMAGE_TAG} -f ${SCRIPT_DIR}/${DOCKER_FILE_PATH} ${build_args} ${extra_build_args} .
    cd ..
}

## now loop through the above array
for openstack_release in "${openstack_releases[@]}"
do
  #Commenting below code as the values are hardcoded in required Dockerfiles

  #if [[ "$openstack_release" == "train" ]]; then
  #  distro_release="bionic"
  #Added mosk as part of TVAULT-5293; added mosk22.3 as part of TVAULT-5318
  #elif [[ "$openstack_release" == "victoria"  || "$openstack_release" == "mosk22.2" || "$openstack_release" == "mosk22.3" ]]; then
  #  distro_release="focal"
  #  OS_REPO="victoria"
  #elif [[ "$openstack_release" == "mosk22.4_victoria"  || "$openstack_release" == "mosk22.4_yoga" ]]; then
  #  distro_release="focal"
  #  OS_REPO="yoga"
  #else
  #  echo "Openstack release not supported $openstack_release"
  #  exit 1
  #fi

  for container_to_build in "${containers_to_build[@]}"
  do
	echo -e "Creating ${container_to_build} container for openstack helm/MOSK ${openstack_release} ${openstack_platform} ${distro_release}"
	build_container "$openstack_release" "${container_to_build}"
  done
done
