# Stage 1: Extract helm-operator binary from the source image
FROM quay.io/operator-framework/helm-operator:v1.38.0 AS source

# Stage 2: Build the custom image
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5 AS base

# Add metadata
LABEL name="trilio/trilio-openstack-operator" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.0.0" \
      release="6.0" \
      summary="Trilio for OpenStack Operator - RHOSO" \
      description="Trilio for OpenStack Operator - RHOSO"

# Set environment variables and working directory
ENV HOME=/opt/helm \
    USER_NAME=helm \
    USER_UID=1001

WORKDIR ${HOME}

# Copy helm-operator binary from the source image
COPY --from=source /usr/local/bin/helm-operator /usr/local/bin/helm-operator

# Copy application-specific files
COPY watches.yaml ${HOME}/watches.yaml
COPY helm-charts ${HOME}/helm-charts
RUN mkdir /licenses
COPY licensing.txt /licenses

# Ensure the application runs as a non-root user
USER ${USER_UID}

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/helm-operator", "run", "--watches-file=./watches.yaml"]

