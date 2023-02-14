FROM registry.access.redhat.com/rhosp13/openstack-horizon
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="rhosp13/openstack-horizon-triliodata-plugin" \
      maintainer="shyam.biradar@trilio.io" \ 
      vendor="TrilioData" \
      version="5.0.X" \
      release="5.0" \
      summary="Red Hat OpenStack Platform 14.0 horizon TrilioData TrilioVault Horizon Plugin" \
      description="Red Hat OpenStack Platform 14.0 horizon TrilioData TrilioVault Horizon Plugin"

##Install datamover packages
ADD trilio.repo /etc/yum.repos.d/
RUN yum install tvault-horizon-plugin python-workloadmgrclient -y
RUN rm /etc/yum.repos.d/trilio.repo

##Move necessary files
ADD usr/share/openstack-dashboard/openstack_dashboard/local/enabled/* /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
ADD usr/share/openstack-dashboard/openstack_dashboard/templatetags/* /usr/share/openstack-dashboard/openstack_dashboard/templatetags/

## Add license
RUN mkdir /licenses
COPY licensing.txt /licenses
