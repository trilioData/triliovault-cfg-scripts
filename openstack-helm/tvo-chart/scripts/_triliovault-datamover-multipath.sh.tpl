#!/bin/bash

chroot /mnt/host-rootfs /usr/bin/env -i PATH="/sbin:/bin:/usr/bin" \
    multipath "${@:1}"