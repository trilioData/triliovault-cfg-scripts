FROM registry.access.redhat.com/rhel7/rhel
MAINTAINER TrilioData
LABEL name="trilio/rhel-binary-datamover-extension" vendor="TrilioData" version="3.1" release="3.1"

##Build arguments
ARG triliovault_version
ARG triliovault_release
ARG redhat_username
ARG redhat_password
ARG redhat_pool_id


# switch to root and install a custom RPM, etc.
USER root

RUN subscription-manager register --user=${redhat_username} \
--password=${redhat_password} && subscription-manager attach --pool ${redhat_pool_id}
RUN yum install sudo python2-cryptography -y
RUN yum clean all
RUN subscription-manager unregister

RUN groupadd nova
RUN useradd -g nova nova


##Install rpm packages
ADD rpms/tvault-contego-${triliovault_version}-${triliovault_release}.noarch.rpm /tmp/
ADD rpms/puppet-triliovault-${triliovault_version}-${triliovault_release}.noarch.rpm /tmp/
RUN rpm -ivh /tmp/puppet-triliovault-${triliovault_version}-${triliovault_release}.noarch.rpm
RUN rpm -ivh /tmp/tvault-contego-${triliovault_version}-${triliovault_release}.noarch.rpm

##Set correct libraries
RUN ln -s /usr/lib64/python2.7/site-packages/cryptography /home/tvault/.virtenv/lib/python2.7/site-packages/cryptography
RUN ln -s /usr/lib64/python2.7/site-packages/cffi /home/tvault/.virtenv/lib/python2.7/site-packages/cffi
RUN cp /usr/lib64/python2.7/site-packages/libvirtmod.so /home/tvault/.virtenv/lib/python2.7/site-packages/libvirtmod.so
RUN cp /usr/lib64/python2.7/site-packages/_cffi_backend.so /home/tvault/.virtenv/lib/python2.7/site-packages/_cffi_backend.so

##Copy conf files
ADD nova-sudoers /etc/sudoers.d/nova-sudoers
ADD --chown=nova:nova tvault-contego.conf /etc/tvault-contego/tvault-contego.conf
COPY tvault-contego.service /etc/systemd/system/tvault-contego.service
ADD --chown=nova:nova trilio-datamover-entrypoint.sh /home/nova/
RUN mkdir -p /var/triliovault-mounts
RUN chown nova:nova /var/triliovault-mounts
RUN mkdir -p /var/triliovault
RUN chmod 777 /var/triliovault-mounts
RUN chown nova:nova /var/triliovault
RUN chmod 777 /var/triliovault
ADD log-rotate-conf /etc/logrotate.d/tvault-contego

##Become nova user for further operations
USER nova
RUN chmod +x /home/nova/trilio-datamover-entrypoint.sh

##Entrypoint
#ENTRYPOINT ["/home/nova/trilio-datamover-entrypoint.sh"]
CMD ["/bin/bash"]
