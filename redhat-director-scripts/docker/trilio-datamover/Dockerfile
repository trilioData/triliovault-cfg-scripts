FROM registry.access.redhat.com/rhosp13/openstack-nova-compute
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="rhosp13/openstack-trilio-datamover-plugin" \
      maintainer="shyam.biradar@trilio.io" \ 
      vendor="TrilioData" \
      version="3.0.73" \
      release="3.0" \
      summary="Trilio Datamover" \
      description="Trilio Datamover for Redhat OpenStack Platform 13"

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

##Set correct libraries
RUN rm -rf /home/tvault/.virtenv/lib/python2.7/site-packages/cryptography
RUN rm -rf /home/tvault/.virtenv/lib/python2.7/site-packages/cffi
RUN ln -s /usr/lib64/python2.7/site-packages/cryptography /home/tvault/.virtenv/lib/python2.7/site-packages/cryptography
RUN ln -s /usr/lib64/python2.7/site-packages/cffi /home/tvault/.virtenv/lib/python2.7/site-packages/cffi
RUN cp /usr/lib64/python2.7/site-packages/libvirtmod.so /home/tvault/.virtenv/lib/python2.7/site-packages/libvirtmod.so
RUN cp /usr/lib64/python2.7/site-packages/_cffi_backend.so /home/tvault/.virtenv/lib/python2.7/site-packages/_cffi_backend.so

##Copy conf files
ADD nova-sudoers /etc/sudoers.d/nova-sudoers
ADD --chown=nova:nova tvault-contego.conf /etc/tvault-contego/tvault-contego.conf
ADD tvault-contego.service /etc/systemd/system/tvault-contego.service
ADD --chown=nova:nova trilio-datamover-entrypoint.sh /home/nova/
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

##Become nova user for further operations
USER nova
RUN chmod +x /home/nova/trilio-datamover-entrypoint.sh

##Entrypoint
ENTRYPOINT ["/home/nova/trilio-datamover-entrypoint.sh"]
CMD ["/bin/bash"]
