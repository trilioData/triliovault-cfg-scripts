FROM registry.access.redhat.com/rhosp13/openstack-nova-compute
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="rhosp13/openstack-nova-compute-triliodata-plugin" \
      maintainer="shyam.biradar@trilio.io" \ 
      vendor="TrilioData" \
      version="3.1.0" \
      release="3.1" \
      summary="Red Hat OpenStack Platform 13.0 nova-compute TrilioData Datamover" \
      description="Red Hat OpenStack Platform 13.0 nova-compute TrilioData Datamover"

##Build arguments (Redhat subscription details)
ARG redhat_username
ARG redhat_password
ARG redhat_pool_id

# switch to root and install a custom RPM, etc.
USER root

RUN subscription-manager register --user=${redhat_username} \
--password=${redhat_password} && subscription-manager attach --pool ${redhat_pool_id}
RUN yum-config-manager --enable rhel-7-server-openstack-13-rpms
RUN yum clean all
RUN yum install sudo python2-cryptography libvirt-python -y
##Install datamover packages
ADD trilio.repo /etc/yum.repos.d/
RUN yum install tvault-contego -y

#Copy executable files
RUN mkdir -p /opt/tvault/
ADD start_datamover start_tvault_contego start_tvault_object_store /opt/tvault/
RUN chown -R nova:nova /opt/tvault/
RUN chmod 755 /opt/tvault/start_datamover /opt/tvault/start_tvault_contego /opt/tvault/start_tvault_object_store

##Set correct libraries
RUN rm -rf /home/tvault/.virtenv/lib/python2.7/site-packages/cryptography
RUN rm -rf /home/tvault/.virtenv/lib/python2.7/site-packages/cffi
RUN ln -s /usr/lib64/python2.7/site-packages/cryptography /home/tvault/.virtenv/lib/python2.7/site-packages/cryptography
RUN ln -s /usr/lib64/python2.7/site-packages/cffi /home/tvault/.virtenv/lib/python2.7/site-packages/cffi
RUN cp /usr/lib64/python2.7/site-packages/libvirtmod.so /home/tvault/.virtenv/lib/python2.7/site-packages/libvirtmod.so
RUN cp /usr/lib64/python2.7/site-packages/_cffi_backend.so /home/tvault/.virtenv/lib/python2.7/site-packages/_cffi_backend.so

##Copy conf files
ADD nova-sudoers /etc/sudoers.d/nova-sudoers
RUN usermod -aG disk nova
ADD --chown=nova:nova tvault-contego.conf /etc/tvault-contego/tvault-contego.conf
RUN mkdir -p /var/triliovault-mounts
RUN chown nova:nova /var/triliovault-mounts
RUN mkdir -p /var/triliovault
RUN chmod 777 /var/triliovault-mounts
RUN chown nova:nova /var/triliovault
RUN chmod 777 /var/triliovault
ADD log-rotate-conf /etc/logrotate.d/tvault-contego

##Clean subscription
RUN yum-config-manager --disable rhel-7-server-openstack-13-rpms
RUN yum clean all
RUN subscription-manager unregister
RUN rm -f /etc/yum.repos.d/trilio.repo

##Add license
RUN mkdir /licenses
COPY licensing.txt /licenses


##Become nova user for further operations
USER nova
