FROM quay.io/openstack.kolla/openstack-base:2025.1-rocky-10
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="kolla/trilio-dms" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.2.0" \
      release="6.2" \
      type="source" \
      summary="TrilioData TrilioVault DMS" \
      description="TrilioData TrilioVault Dynamic Mount Service (Rocky Linux 10)"

USER root

RUN dnf clean all
RUN dnf config-manager --save --setopt=epel.skip_if_unavailable=true

ADD trilio.repo /etc/yum.repos.d/

RUN dnf install -y \
    fuse fuse-libs nfs-utils \
    python3-triliovault-dms-el10 \
    python3-s3fuse-plugin-el10

RUN ldconfig

RUN /usr/bin/pip3 install --upgrade pip \
    && /usr/bin/pip3 install azure-storage-blob azure-core loguru

RUN echo "user_allow_other" > /etc/fuse.conf

RUN groupadd -f -g 42436 nova \
    && id nova &>/dev/null || useradd -u 42436 -g 42436 -m -s /bin/bash nova \
    && usermod -aG kolla nova

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

COPY extend_start.sh /usr/local/bin/kolla_extend_start

RUN mkdir -p /opt/triliovault && chown -R nova:nova /opt/triliovault

RUN dnf clean all
RUN rm -f /etc/yum.repos.d/trilio.repo

RUN mkdir /licenses
COPY licensing.txt /licenses

USER nova
