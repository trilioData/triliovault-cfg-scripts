FROM registry.access.redhat.com/rhosp13/openstack-horizon
MAINTAINER TrilioData shyam.biradar@trilio.io

LABEL name="rhosp13/openstack-horizon-with-trilio-plugin" \
      maintainer="shyam.biradar@trilio.io" \ 
      vendor="TrilioData" \
      version="3.1.0" \
      release="3.1" \
      summary="OpenStack horizon with Trilio Horizon Plugin" \
      description="OpenStack Horizon container with Trilio plugin for Redhat OpenStack Platform 13"

# switch to root and install a custom RPM, etc.
USER root


##Install datamover packages
ADD trilio.repo /etc/yum.repos.d/
RUN yum install tvault-horizon-plugin python-workloadmgrclient -y
RUN rm /etc/yum.repos.d/trilio.repo

##Move necessary files
ADD usr/share/openstack-dashboard/openstack_dashboard/local/enabled/* /usr/share/openstack-dashboard/openstack_dashboard/local/enabled/
ADD usr/share/openstack-dashboard/openstack_dashboard/templatetags/* /usr/share/openstack-dashboard/openstack_dashboard/templatetags/
