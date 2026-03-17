FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4
MAINTAINER TrilioData shyam.biradar@trilio.io
LABEL name="trilio/openstack-nova-compute-triliodata-plugin" \
      maintainer="shyam.biradar@trilio.io" \ 
      vendor="TrilioData" \
      version="6.2.0" \
      release="6.2" \
      summary="Red Hat OpenStack Platform 18 TrilioData TrilioVault Dynamic Mount Service" \
      description="Red Hat OpenStack Platform 18 TrilioData TrilioVault Dynamic Mount Service"


USER root


ARG UID=42424
ARG GID=42424
ENV TZ=Etc/UTC \
    LIBGUESTFS_DEBUG=1 \
    LIBGUESTFS_TRACE=1
RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-setuptools \
        python3-wheel \
        fuse \
        fuse3 \
        nfs-common \
        ca-certificates \
        vim \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p \
    /var/trilio \
    /var/lib/trilio/triliovault-mounts \
    /opt/triliovault-dms \
    /etc/triliovault-dms \
    /var/log/triliovault \
    /run/dms/s3 \
    && chmod 777 /var/trilio \
    && chmod 777 /var/lib/trilio/triliovault-mounts

RUN groupadd -g ${GID} nova \
    && useradd -u ${UID} -g ${GID} -m -s /bin/bash nova

RUN chown -R nova:nova \
    /var/trilio \
    /var/lib/trilio/triliovault-mounts \
    /opt/triliovault-dms \
    /etc/triliovault-dms \
    /var/log/triliovault \
    /run/dms/s3


# Copy rootwrap config files
RUN mkdir -p /etc/triliovault-dms/rootwrap.d \
    && cp rootwrap.conf /etc/triliovault-dms/rootwrap.conf \
    && cp dms.filters /etc/triliovault-dms/rootwrap.d/dms.filters

# Install sudoers rule
RUN cp trilio-dms-sudoers /etc/sudoers.d/trilio-dms \
    && chmod 0440 /etc/sudoers.d/trilio-dms \
    && chown root:root /etc/sudoers.d/trilio-dms 

 
# Copy packages into image
#COPY s3fuse-6.1.7.tar.gz /tmp/
COPY trilio-dms-1.0.0.tar.gz /tmp/

# Install python packages
RUN pip3 install --upgrade pip setuptools wheel \
    && pip3 install /tmp/trilio-dms-1.0.0.tar.gz

RUN mkdir -p /licenses
COPY licensing.txt /licenses

USER nova