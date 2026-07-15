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

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

USER root

RUN apt-get -y update && \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        python3-pip \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Install TrilioVault DataMover API packages from Trilio APT repo
ADD trilio.list /etc/apt/sources.list.d/
RUN apt-get update -y && \
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y \
        python3-dmapi \
        python3-trilio-dms \
    --allow-unauthenticated && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/apt/sources.list.d/trilio.list

# Create required directories — dmapi package creates the dmapi user/group
RUN mkdir -p \
    /etc/triliovault-datamover \
    /etc/triliovault-dms \
    /var/log/triliovault \
    /var/cache/dmapi

RUN chown -R dmapi:dmapi \
        /var/log/triliovault \
        /var/cache/dmapi \
        /etc/triliovault-datamover \
        /etc/triliovault-dms && \
    chmod -R 755 \
        /var/log/triliovault \
        /etc/triliovault-datamover \
        /etc/triliovault-dms
