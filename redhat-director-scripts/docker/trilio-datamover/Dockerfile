FROM registry.access.redhat.com/rhosp13/openstack-nova-compute
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="rhosp13/openstack-nova-compute-triliodata-plugin" \
      maintainer="shyam.biradar@trilio.io" \ 
      vendor="TrilioData" \
      version="3.1.0" \
      release="3.1" \
      summary="Red Hat OpenStack Platform 13.0 nova-compute TrilioData Datamover" \
      description="Red Hat OpenStack Platform 13.0 nova-compute TrilioData Datamover"

# switch to root and install a custom RPM, etc.
USER root

##Install datamover packages
ADD trilio.repo /etc/yum.repos.d/
RUN yum install tvault-contego puppet-triliovault -y

#Copy executable files
RUN mkdir -p /opt/tvault/
ADD start_datamover_s3 start_datamover_nfs start_tvault_object_store /opt/tvault/
RUN chown -R nova:nova /opt/tvault/
RUN chmod 755 /opt/tvault/start_datamover_s3 /opt/tvault/start_datamover_nfs /opt/tvault/start_tvault_object_store

##Copy conf files
ADD nova-sudoers /etc/sudoers.d/nova-sudoers
RUN usermod -aG disk nova
ADD tvault-contego.conf /etc/tvault-contego/tvault-contego.conf
RUN chown nova:nova /etc/tvault-contego/tvault-contego.conf
RUN mkdir -p /var/triliovault-mounts
RUN chown nova:nova /var/triliovault-mounts
RUN mkdir -p /var/triliovault
RUN chmod 777 /var/triliovault-mounts
RUN chown nova:nova /var/triliovault
RUN chmod 777 /var/triliovault
ADD log-rotate-conf /etc/logrotate.d/tvault-contego

##Clean subscription
RUN yum clean all
RUN rm -f /etc/yum.repos.d/trilio.repo

##Add license
RUN mkdir /licenses
COPY licensing.txt /licenses


##Become nova user for further operations
USER nova
