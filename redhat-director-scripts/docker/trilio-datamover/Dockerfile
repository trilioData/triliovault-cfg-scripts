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
RUN subscription-manager register --user=$redhat_username \
--password=$redhat_password && subscription-manager attach --pool $redhat_pool_id
RUN yum install sudo -y
RUN groupadd nova
RUN useradd -g nova nova

##Install rpm package
ADD rpms/tvault-contego-${triliovault_version}-${triliovault_release}.noarch.rpm /tmp/
ADD rpms/puppet-triliovault-${triliovault_version}-${triliovault_release}.noarch.rpm /tmp/
RUN rpm -ivh /tmp/puppet-triliovault-${triliovault_version}-${triliovault_release}.noarch.rpm
RUN rpm -ivh /tmp/tvault-contego-${triliovault_version}-${triliovault_release}.noarch.rpm

##Copy conf files
COPY tvault-contego.conf /etc/tvault-contego/tvault-contego.conf
COPY tvault-contego.service /etc/systemd/system/tvault-contego.service
COPY trilio-datamover-entrypoint.sh /
RUN chmod +x /trilio-datamover-entrypoint.sh

USER nova
##Entrypoint
ENTRYPOINT ["/trilio-datamover-entrypoint.sh"]
