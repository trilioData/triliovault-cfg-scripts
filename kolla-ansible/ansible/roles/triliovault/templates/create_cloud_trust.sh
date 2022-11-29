#!/bin/bash

##Ensure cloudrc is present
cloudrc=/opt/triliovault-cloudrc

if [[ -f "$cloudrc" ]]; then
	printf "Cloudrc found at $cloudrc \n\n Run command to create cloud admin trust\n"
	. $cloudrc && workloadmgr trust-create --is_cloud_trust True admin --insecure
	printf "...\n"
else
	printf "Failed to create cloud admin trust, cause cloudrc not found at $cloudrc"
fi
