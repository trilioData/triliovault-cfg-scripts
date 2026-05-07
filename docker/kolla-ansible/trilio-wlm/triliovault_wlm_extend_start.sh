#!/bin/bash

# Bootstrap and exit if KOLLA_BOOTSTRAP variable is set. This catches all cases
# of the KOLLA_BOOTSTRAP variable being set, including empty.

## TODO: Uncomment following code once we get dmapi-dbsync tool

if [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    alembic --config /etc/triliovault-wlm/triliovault-wlm.conf upgrade head
    exit 0
fi

if [[ "${!KOLLA_UPGRADE[@]}" ]]; then
    alembic --config /etc/triliovault-wlm/triliovault-wlm.conf upgrade head
    exit 0
fi
