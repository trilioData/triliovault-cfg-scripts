FROM ubuntu:22.04

LABEL maintainer="Trilio Data, Inc. <support@trilio.io>"
LABEL description="TrilioVault WorkloadManager for Canonical OpenStack (Sunbeam)"

ARG TRILIO_VERSION=6.2.1
ARG OPENSTACK_RELEASE=2024.1
ARG DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ca-certificates \
    python3 \
    python3-pip \
    python3-setuptools \
    && rm -rf /var/lib/apt/lists/*

# Add Trilio apt repo and install workloadmgr
RUN curl -fsSL https://apt.trilio.io/key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/trilio.gpg \
    && echo "deb [trusted=yes] https://apt.trilio.io jammy main" \
       > /etc/apt/sources.list.d/trilio.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       "workloadmgr=${TRILIO_VERSION}*" \
    && rm -rf /var/lib/apt/lists/*

# Create required directories and user
RUN groupadd -r wlm && useradd -r -g wlm -d /var/lib/workloadmgr -s /sbin/nologin wlm \
    && mkdir -p /etc/workloadmgr /var/log/workloadmgr /var/lib/workloadmgr \
    && chown -R wlm:wlm /etc/workloadmgr /var/log/workloadmgr /var/lib/workloadmgr

# Config is written by charm via Pebble push; provide an empty default
RUN touch /etc/workloadmgr/workloadmgr.conf \
    && chown wlm:wlm /etc/workloadmgr/workloadmgr.conf

# Ports
# 8780 - WLM API
EXPOSE 8780

USER wlm
