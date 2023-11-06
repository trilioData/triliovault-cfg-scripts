#!/bin/bash -x

systemctl disable tripleo_triliovault_datamover.service
systemctl stop tripleo_triliovault_datamover.service

umount /var/lib/nova/triliovault-mounts
ls /var/lib/nova/triliovault-mounts