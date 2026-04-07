FROM registry.redhat.io/rhoso/openstack-base-rhel9:18.0
MAINTAINER TrilioData shyam.biradar@trilio.io
LABEL name="trilio/openstack-nova-compute-triliodata-plugin" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.2.0" \
      release="6.2" \
      summary="Red Hat OpenStack Platform 18 TrilioData TrilioVault Dynamic Mount Service" \
      description="Red Hat OpenStack Platform 18 TrilioData TrilioVault Dynamic Mount Service"


USER root
##Install datamover packages
RUN dnf clean all && dnf config-manager --set-disabled \*
ADD trilio.repo /etc/yum.repos.d/

RUN dnf config-manager \
  --enable rhel-9-for-x86_64-baseos-eus-rpms \
  --enable rhel-9-for-x86_64-appstream-eus-rpms \
  --enable rhel-9-for-x86_64-highavailability-eus-rpms \
  --enable fast-datapath-for-rhel-9-x86_64-rpms \
  --enable rhceph-7-tools-for-rhel-9-x86_64-rpms \
  --enable rhoso-18.0-for-rhel-9-x86_64-rpms

ARG UID=42436
ARG GID=42436
ENV TZ=Etc/UTC \
    LIBGUESTFS_DEBUG=1 \
    LIBGUESTFS_TRACE=1
RUN groupadd -g ${GID} nova \
    && useradd -u ${UID} -g ${GID} -m -s /bin/bash nova \
    && usermod -aG kolla nova \
    && dnf install -y --releasever 9.6 python3-devel python3-pip nfs-utils mysql \
    && dnf install -y --releasever 9.6 python3-trilio-dms-el9 \
    && dnf install -y --releasever 9.6 https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

## Epel repo is needed for ntfs-3g package
RUN dnf install --releasever 9.6 -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    && sed -i 's/\$releasever/9/g' /etc/yum.repos.d/epel.repo \
    && dnf config-manager --disable epel-cisco-openh264

## Enable openstack-17.1-for-rhel-9-x86_64-rpms for eventlet 
RUN dnf config-manager --enable openstack-17.1-for-rhel-9-x86_64-rpms \
    && dnf -y --releasever 9.6 install python3-s3fuse-plugin-el9 \
    && dnf config-manager --disable openstack-17.1-for-rhel-9-x86_64-rpms

RUN dnf erase --releasever 9.6 -y epel-release

RUN pip3 install --upgrade pip && pip3 install azure-storage-blob==12.25.1 azure-core loguru

RUN mkdir -p \
    /var/lib/trilio/triliovault-mounts \
    /etc/triliovault-dms \
    /etc/triliovault-dms/client.conf.d \
    /var/log/triliovault \
    /run/dms/s3 \
    && chmod 777 /var/lib/trilio/triliovault-mounts \
    && chown -R nova:nova \
    /var/lib/trilio/triliovault-mounts \
    /var/log/triliovault \
    /run/dms/s3 \
    /etc/triliovault-dms


##Disable repos and Clean subscription
RUN dnf config-manager \
    --disable rhel-9-for-x86_64-baseos-eus-rpms \
    --disable rhel-9-for-x86_64-appstream-eus-rpms \
    --disable rhel-9-for-x86_64-highavailability-eus-rpms \
    --disable fast-datapath-for-rhel-9-x86_64-rpms \
    --disable rhceph-7-tools-for-rhel-9-x86_64-rpms \
    --disable rhoso-18.0-for-rhel-9-x86_64-rpms \
    && dnf clean all

RUN mkdir -p /licenses
COPY licensing.txt /licenses

USER nova
