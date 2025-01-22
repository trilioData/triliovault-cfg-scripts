FROM quay.io/openstack-k8s-operators/openstack-ansibleee-runner:latest
LABEL name="trilio/trilio-rhoso-ansible-runner" \
      maintainer="shyam.biradar@trilio.io" \
      vendor="TrilioData" \
      version="6.0.0" \
      release="6.0" \
      summary="Trilio Ansible Runner for RHOSO" \
      description="Trilio Ansible Runner for RHOSO"
COPY ansible-roles/trilio-datamover /usr/share/ansible/roles/trilio-datamover
RUN chmod -R 777 /usr/share/ansible/roles/trilio-datamover

RUN mkdir /licenses
COPY licensing.txt /licenses
