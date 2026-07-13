FROM ubuntu:22.04

LABEL maintainer="Trilio Data, Inc. <support@trilio.io>"
LABEL description="TrilioVault Horizon Plugin image for Canonical OpenStack (Sunbeam)"

ARG TRILIO_VERSION=6.2.1
ARG OPENSTACK_HORIZON_IMAGE=ubuntu/horizon:latest
ARG DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ca-certificates \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Add Trilio apt repo and install horizon plugin
RUN curl -fsSL https://apt.trilio.io/key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/trilio.gpg \
    && echo "deb [trusted=yes] https://apt.trilio.io jammy main" \
       > /etc/apt/sources.list.d/trilio.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       "python3-workloadmgrclient=${TRILIO_VERSION}*" \
       "tvault-horizon-plugin=${TRILIO_VERSION}*" \
    && rm -rf /var/lib/apt/lists/*

# Enable the Trilio dashboard panel in Horizon
# The horizon-k8s charm loads /usr/share/openstack-dashboard/local/enabled/*.py
# Trilio plugin installs its enabled file during package installation.

# No separate entrypoint needed — horizon-k8s charm manages the process
# and injects this image's site-packages into the running Horizon container
# via "juju attach-resource horizon-k8s horizon-image=<this-image>"
