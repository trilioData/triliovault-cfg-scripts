FROM quay.io/operator-framework/helm-operator:v1.38.0

# Add metadata
LABEL name="trilio/trilio-openstack-operator" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.0.0" \
      release="6.0" \
      summary="Trilio for OpenStack Operator - RHOSO" \
      description="Trilio for OpenStack Operator - RHOSO"

USER root
RUN mkdir /licenses
COPY licensing.txt /licenses

USER 1001
ENV HOME=/opt/helm
COPY watches.yaml ${HOME}/watches.yaml
COPY helm-charts ${HOME}/helm-charts


WORKDIR ${HOME}
