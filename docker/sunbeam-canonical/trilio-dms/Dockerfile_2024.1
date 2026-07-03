FROM quay.io/openstack.kolla/nova-api:2024.1-ubuntu-jammy
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="sunbeam/trilio-dms" \
      vendor="TrilioData" \
      version="6.2.0" \
      release="6.2" \
      summary="TrilioData Dynamic Mount Service" \
      description="TrilioData TrilioVault Dynamic Mount Service Image based on Ubuntu Jammy for Sunbeam Canonical OpenStack"

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

ADD trilio.list /etc/apt/sources.list.d/

RUN apt-get update -y \
    && apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y \
        fuse libfuse2 nfs-common \
        python3-trilio-dms python3-s3-fuse-plugin --allow-unauthenticated \
    && /usr/bin/pip3 install --upgrade pip \
    && /usr/bin/pip3 install azure-storage-blob==12.25.1 azure-core loguru \
    && apt-get clean -y

RUN echo "user_allow_other" > /etc/fuse.conf

RUN usermod -u 42436 nova && groupmod -g 42436 nova && usermod -aG disk nova

RUN mkdir -p \
    /var/lib/trilio/triliovault-mounts \
    /var/triliovault \
    /etc/triliovault-dms/client.conf.d \
    /var/log/triliovault \
    /run/dms/s3 \
    && chmod 777 /var/lib/trilio/triliovault-mounts \
    && chown -R nova:nova \
        /var/lib/trilio/triliovault-mounts \
        /var/log/triliovault \
        /run/dms \
        /etc/triliovault-dms

RUN mkdir -p /opt/triliovault && chown -R nova:nova /opt/triliovault

RUN mkdir -p /licenses
COPY licensing.txt /licenses

RUN rm -f /etc/apt/sources.list.d/trilio.list

USER nova
