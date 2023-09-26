#!/bin/bash

set -x
##Ensure cloudrc is present
cloudrc=/opt/triliovault-cloudrc

if [[ -f "$cloudrc" ]]; then
        printf "Cloudrc found at $cloudrc \n\n Run command to create cloud admin trust\n"
        . $cloudrc
        for attempt in {1..5};
        do
                echo -e "Attempting to create wlm-cloud admin trust, Attempt Number: $attempt"
                command_output=$(workloadmgr trust-create --is_cloud_trust True admin --insecure 2>&1)
                echo "Command output: $command_output"
                status=$?
                if [[ $command_output == *"Service Unavailable"* ]]; then
                        echo -e "wlm cloud admin trust create command failed due to wlm service unavailability. Will re-try after 30 seconds"
                        if [ $attempt -eq 5 ]; then
                           echo -e "Five attempts done, but wlm cloud trust creation still failing. Exiting."
                           exit $status
                        fi
                        sleep 30s
                        continue
                elif [ $status -eq 0 ]; then
                        echo -e "wlm cloud admin trust created successfully"
                        break
                else
                        echo -e "wlm cloud admin trust creation failed, exiting"
                        break
                fi
        done
else
        printf "Failed to create cloud admin trust, cause cloudrc not found at $cloudrc"
fi
