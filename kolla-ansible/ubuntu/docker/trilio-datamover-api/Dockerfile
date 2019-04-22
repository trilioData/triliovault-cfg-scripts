FROM kolla/ubuntu-source-nova-api:pike
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="kolla/openstack-nova-api-triliodata-plugin" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="3.1.0" \
      release="3.1" \
      summary="TrilioData trilio-datamover-api" \
      description="TrilioData trilio-datamover-api"


# switch to root and install a custom RPM, etc.
USER root

##Install datamover packages
# This IP (10.17.0.12) is the TrilioVault VM, only accessible for now

RUN echo "deb http://10.17.0.12:8085 deb-repo/" >> /etc/apt/sources.list \
 && apt-get update -y \
 && apt-get install -y dmapi --allow-unauthenticated


RUN mkdir -p /var/log/dmapi/ \
    /var/cache/dmapi/ \
    /etc/nova \
    /var/log/kolla/dmapi \
 && chown -R nova:nova /var/log/dmapi/ \
 && chown -R nova:nova /var/log/kolla/dmapi \
 && chown nova:nova /var/cache/dmapi/ \
 && rm /etc/dmapi/dmapi.conf

##Copy license file
RUN mkdir /licenses
COPY licensing.txt /licenses

##Become nova user for further operations
USER nova

##################
# REQUIRED MOUNTS#
##################
# /etc/kolla/dmapi/nova.conf:/etc/nova/nova.conf
# /etc/kolla/dmapi/dmapi.conf:/etc/dmapi/dmapi.conf

##############
# RUN COMMAND#
##############
# docker run --network host --name trilio_dmapi -d -v /etc/kolla/dmapi/nova.conf:/etc/nova/nova.conf -v /etc/kolla/dmapi/dmapi.conf:/etc/dmapi/dmapi.conf kolla/ubuntu-source-trilio-dmapi:pike /var/lib/kolla/venv/bin/python /usr/bin/dmapi-api
