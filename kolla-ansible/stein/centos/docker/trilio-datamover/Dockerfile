FROM kolla/centos-source-nova-compute:stein
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="kolla/trilio-datamover" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="3.3.0" \
      release="3.3" \
      summary="TrilioData Datamover" \
      description="TrilioData Datamover"

# switch to root and install a custom RPM, etc.
USER root

##Install datamover packages
ADD trilio.repo /etc/yum.repos.d/
RUN yum install tvault-contego puppet-triliovault -y

#Copy executable files
RUN mkdir -p /opt/tvault/ 
ADD start_datamover_s3 start_datamover_nfs start_tvault_object_store /opt/tvault/
RUN chown -R nova:nova /opt/tvault/ \
   && chmod 755 /opt/tvault/start_datamover_s3 /opt/tvault/start_datamover_nfs /opt/tvault/start_tvault_object_store

##Copy conf files
ADD nova-sudoers /etc/sudoers.d/nova-sudoers
ADD trilio.filters /usr/share/nova/rootwrap/trilio.filters
RUN usermod -aG disk nova \
 && usermod -aG kvm nova

# ADD tvault-contego.conf /etc/tvault-contego/tvault-contego.conf
# RUN chown nova:nova /etc/tvault-contego/tvault-contego.conf

RUN mkdir -p /var/triliovault-mounts \
 && chown nova:nova /var/triliovault-mounts \
 && mkdir -p /var/triliovault \
 && chmod 777 /var/triliovault-mounts \
 && chown nova:nova /var/triliovault \
 && chmod 777 /var/triliovault

ADD log-rotate-conf /etc/logrotate.d/tvault-contego

##Clean subscription
RUN yum clean all
RUN rm -f /etc/yum.repos.d/trilio.repo

##Add license
RUN mkdir /licenses
COPY licensing.txt /licenses


##Become nova user for further operations
USER nova

##################
# REQUIRED MOUNTS#
##################
# /etc/kolla/datamover/nova.conf:/etc/nova/nova.conf
# /etc/kolla/datamover/tvault-contego.conf:/etc/tvault-contego/tvault-contego.conf
# /etc/kolla/datamova/ceph.conf:/etc/ceph/ceph.conf
# /etc/kolla/datamova/ceph.client.nova.keyring:/etc/ceph/ceph.client.nova.keyring
# iscsi_info:/etc/iscsi:rw
# /dev:/dev:rw
# nova_compute:/var/lib/nova/:rw
# /var/run/libvirt
# /etc/kolla/datamover/start_datamover_nfs:/opt/tvault/start_datamover_nfs

## start_datamover_nfs was needed because it wasn't using NFS correctly

##############
# RUN COMMAND#
##############
# docker run --network host --name trilio_datamover -d -v /etc/kolla/dmapi/nova.conf:/etc/nova/nova.conf -v /etc/kolla/datamover/tvault-contego.conf:/etc/tvault-contego/tvault-contego.conf kolla/ubuntu-source-trilio-datamover:pike

