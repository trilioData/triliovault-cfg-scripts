FROM ubuntu:22.04

LABEL maintainer="Trilio Data, Inc. <support@trilio.io>"
LABEL description="TrilioVault DataMover API for Canonical OpenStack (Sunbeam)"

ARG TRILIO_VERSION=6.2.1
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

# Add Trilio apt repo and install dmapi
RUN curl -fsSL https://apt.trilio.io/key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/trilio.gpg \
    && echo "deb [trusted=yes] https://apt.trilio.io jammy main" \
       > /etc/apt/sources.list.d/trilio.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       "dmapi=${TRILIO_VERSION}*" \
    && rm -rf /var/lib/apt/lists/*

# Create required directories and user
RUN groupadd -r dmapi && useradd -r -g dmapi -d /var/lib/dmapi -s /sbin/nologin dmapi \
    && mkdir -p /etc/dmapi /var/log/dmapi /var/lib/dmapi \
    && chown -R dmapi:dmapi /etc/dmapi /var/log/dmapi /var/lib/dmapi

# Config is written by charm via Pebble push; provide an empty default
RUN touch /etc/dmapi/dmapi.conf \
    && chown dmapi:dmapi /etc/dmapi/dmapi.conf

# Port
# 8784 - DM-API
EXPOSE 8784

USER dmapi
