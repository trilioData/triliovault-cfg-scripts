#!/bin/bash -x

cp kolla-build.conf /etc/kolla/
kolla-build --base-image registry.access.redhat.com/rhel7/rhel --base rhel --template-override horizon_template_overrides.j2 horizon
