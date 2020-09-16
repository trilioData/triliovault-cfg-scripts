#!/bin/bash

# Bootstrap and exit if KOLLA_BOOTSTRAP variable is set. This catches all cases
# of the KOLLA_BOOTSTRAP variable being set, including empty.

## TODO: Uncomment following code once we get dmapi-dbsync tool

if [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    dmapi-dbsync
    exit 0
fi

if [[ "${!KOLLA_UPGRADE[@]}" ]]; then
    dmapi-dbsync
    exit 0
fi

ls /etc/dmapi