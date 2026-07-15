FROM ubuntu:jammy
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="trilio-dms-canonical" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.2.1" \
      release="6.2" \
      type="source" \
      summary="TrilioVault Dynamic Mount Service (k8s) for Canonical Sunbeam" \
      description="TrilioVault DMS server on Ubuntu Jammy for Sunbeam k8s control plane"

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

# Base packages + ubuntu-cloud-keyring (provides UCA signing key without keyserver access)
RUN apt-get -y update && \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        gnupg \
        fuse \
        libfuse2 \
        nfs-common \
        python3-pip \
        ubuntu-cloud-keyring \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Allow non-root FUSE mounts inside the container
RUN echo "user_allow_other" > /etc/fuse.conf

# Add Ubuntu Cloud Archive for OpenStack Caracal (2024.1)
# Write source entry directly — ubuntu-cloud-keyring already ships the signing key
RUN echo "deb https://ubuntu-cloud.archive.canonical.com/ubuntu jammy-updates/caracal main" \
        > /etc/apt/sources.list.d/cloudarchive-caracal.list && \
    apt-get update -y

# Install nova-common to create nova user/group
RUN apt-get install -y nova-common && apt-get clean -y

# Normalize nova UID/GID to 42436 (matches Sunbeam cluster)
COPY nova_userid.sh /opt/triliovault-dms/nova_userid.sh
RUN chmod +x /opt/triliovault-dms/nova_userid.sh && /opt/triliovault-dms/nova_userid.sh

# pip packages: cloud storage backends + kombu (RabbitMQ client, not in ubuntu:jammy universe)
RUN pip3 --no-cache-dir install \
    azure-storage-blob==12.25.1 \
    azure-core \
    loguru \
    kombu

# Install TrilioVault DMS packages from Trilio APT repo
ADD trilio.list /etc/apt/sources.list.d/
RUN apt-get update -y && \
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y \
        python3-trilio-dms \
        python3-s3-fuse-plugin \
    --allow-unauthenticated && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/apt/sources.list.d/trilio.list

# Create required directories — DMS runs as nova user
RUN mkdir -p \
    /var/lib/trilio/triliovault-mounts \
    /var/triliovault \
    /etc/triliovault-dms \
    /var/log/triliovault \
    /run/dms/s3

RUN chown -R nova:nova \
        /var/lib/trilio/triliovault-mounts \
        /var/log/triliovault \
        /run/dms \
        /etc/triliovault-dms && \
    chmod 777 /var/lib/trilio/triliovault-mounts && \
    chmod -R 755 /etc/triliovault-dms /var/log/triliovault

USER nova
