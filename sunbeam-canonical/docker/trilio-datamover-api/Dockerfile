FROM ubuntu:jammy
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="trilio-datamover-api-canonical" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.2.1" \
      release="6.2" \
      type="source" \
      summary="TrilioVault DataMover API for Canonical Sunbeam" \
      description="TrilioVault DataMover API (dmapi) on Ubuntu Jammy for Sunbeam k8s"

USER root

ARG OPENSTACK_REPO=cloud-archive:caracal

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

# Base packages
RUN apt-get -y update && \
    apt-get -y install --no-install-recommends \
        apt-utils \
        software-properties-common \
        ca-certificates \
        gnupg \
        sudo \
        python3-pip \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Add Ubuntu Cloud Archive for OpenStack Caracal (2024.1)
RUN apt-add-repository ${OPENSTACK_REPO} && apt-get update -y

# Install nova-common (creates nova user) + python3-nova client libs needed by dmapi
RUN apt-get install -y \
        nova-common \
        python3-nova \
        python3-novaclient \
    && apt-get clean -y

# Normalize nova UID/GID to 42436 (matches Sunbeam cluster)
COPY nova_userid.sh /opt/triliovault-datamover/nova_userid.sh
RUN chmod +x /opt/triliovault-datamover/nova_userid.sh && /opt/triliovault-datamover/nova_userid.sh

# Install TrilioVault DataMover API packages from Trilio APT repo
# python3-dmapi creates the dmapi user/group
ADD trilio.list /etc/apt/sources.list.d/
RUN apt-get update -y && \
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y \
        python3-dmapi \
        python3-trilio-dms \
    --allow-unauthenticated && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/apt/sources.list.d/trilio.list

# Create required directories — dmapi service runs as dmapi user
RUN mkdir -p \
    /etc/triliovault-datamover \
    /etc/triliovault-dms \
    /var/log/triliovault \
    /var/cache/dmapi \
    /opt/triliovault

RUN chown -R dmapi:dmapi \
        /var/log/triliovault \
        /var/cache/dmapi \
        /etc/triliovault-datamover \
        /etc/triliovault-dms \
        /opt/triliovault && \
    chmod -R 755 \
        /var/log/triliovault \
        /etc/triliovault-datamover \
        /etc/triliovault-dms

ADD dmapi_sudoers /etc/sudoers.d/dmapi_sudoers
RUN chmod 440 /etc/sudoers.d/dmapi_sudoers

USER dmapi
