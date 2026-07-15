FROM ubuntu:jammy
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="trilio-wlm-canonical" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.2.1" \
      release="6.2" \
      type="source" \
      summary="TrilioVault WorkloadManager for Canonical Sunbeam" \
      description="TrilioVault WLM (wlm-api, wlm-workloads, wlm-scheduler, wlm-cron) on Ubuntu Jammy for Sunbeam k8s"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

USER root

# System dependencies required by WLM
RUN apt-get -y update && \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        sudo \
        nfs-common \
        zlib1g-dev \
        libpython3-dev \
        libcurl4-openssl-dev \
        libssl-dev \
        python3-m2crypto \
        libmysqlclient-dev \
        qemu-utils \
        libxml2-dev \
        libxslt-dev \
        libvirt-clients \
        python3-pip \
        python3-neutronclient \
        python3-glanceclient \
        alembic \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 --no-cache-dir install "SQLAlchemy==1.4.51" && \
    pip3 --no-cache-dir install --upgrade pyvmomi munch paramiko taskflow && \
    pip3 --no-cache-dir install azure-storage-blob==12.25.1 azure-core loguru

# Install TrilioVault WLM packages from Trilio APT repo
ADD trilio.list /etc/apt/sources.list.d/
RUN apt-get update -y && \
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y \
        workloadmgr \
        python3-workloadmgrclient \
        python3-contegoclient \
        python3-trilio-dms \
        python3-s3-fuse-plugin \
    --allow-unauthenticated && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/apt/sources.list.d/trilio.list

# Create required directories
RUN mkdir -p \
    /etc/triliovault-wlm \
    /etc/triliovault-object-store \
    /etc/triliovault-dms \
    /var/trilio/triliovault-mounts \
    /var/triliovault \
    /var/log/triliovault \
    /var/lib/workloadmgr/taskflow

# Set ownership — workloadmgr package creates the nova user/group
RUN chown -R nova:nova \
        /var/log/triliovault \
        /var/trilio/triliovault-mounts \
        /var/triliovault \
        /var/lib/workloadmgr && \
    chown -R root:nova \
        /etc/triliovault-wlm \
        /etc/triliovault-object-store \
        /etc/triliovault-dms && \
    chmod -R 755 \
        /var/log/triliovault \
        /etc/triliovault-wlm \
        /etc/triliovault-object-store && \
    chmod -R 777 \
        /var/trilio/triliovault-mounts \
        /var/triliovault

ADD nova-sudoers /etc/sudoers.d/nova-sudoers
RUN chmod 440 /etc/sudoers.d/nova-sudoers
