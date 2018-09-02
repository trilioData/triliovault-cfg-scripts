FROM registry.access.redhat.com/rhosp13/openstack-nova-api
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="rhosp13/openstack-trilio-dmapi-plugin" \
      maintainer="shyam.biradar@trilio.io" \ 
      vendor="TrilioData" \
      version="3.1.8" \
      release="3.1" \
      summary="Trilio Datamover Api" \
      description="Trilio Datamover Api for Redhat OpenStack Platform 13"

##Build arguments (Redhat subscription details)
ARG tag

# switch to root and install a custom RPM, etc.
USER root


##Install datamover packages
ADD trilio-${tag}.repo /etc/yum.repos.d/
RUN yum install dmapi -y
RUN mkdir -p /var/log/dmapi/
RUN chown nova:nova /var/log/dmapi/
RUN mkdir -p /var/cache/dmapi/
RUN chown nova:nova /var/cache/dmapi/
##Become nova user for further operations
USER nova

##Default command
#CMD /usr/bin/python
