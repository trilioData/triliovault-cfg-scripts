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
#ARG redhat_username
#ARG redhat_password
#ARG redhat_pool_id
ARG tag

# switch to root and install a custom RPM, etc.
USER root

#RUN subscription-manager register --user=${redhat_username} \
#--password=${redhat_password} && subscription-manager attach --pool ${redhat_pool_id}
#RUN yum-config-manager --enable rhel-7-server-openstack-13-rpms
#RUN yum clean all

##Install datamover packages
ADD trilio-${tag}.repo /etc/yum.repos.d/
RUN yum install dmapi -y

##Copy conf files
#ADD --chown=nova:nova dmapi.conf /etc/dmapi/dmapi.conf
#ADD log-rotate-conf /etc/logrotate.d/dmapi

##Clean subscription
#RUN yum-config-manager --disable rhel-7-server-openstack-13-rpms
#RUN yum clean all
#RUN subscription-manager unregister

##Become nova user for further operations
USER nova

##Default command
CMD /usr/bin/python /usr/bin/dmapi-api-wsgi
