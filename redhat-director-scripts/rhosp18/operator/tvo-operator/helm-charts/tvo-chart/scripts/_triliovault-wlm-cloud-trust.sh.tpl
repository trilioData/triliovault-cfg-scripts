#!/bin/bash
set -ex
source /tmp/triliovault-cloudrc
export OS_PROJECT_ID=$(openstack project show -f value -c id "${OS_PROJECT_NAME}")

sleep 2m
for attempt in {1..10};
do
        echo -e "Attempting to create wlm-cloud admin trust, Attempt Number: $attempt"
        command_output=$(workloadmgr trust-create --is_cloud_trust True admin --insecure 2>&1)
        status=$?
        echo "Command output: $command_output"
        if echo "$command_output" | grep -q "unavailable"; then
            echo -e "wlm cloud admin trust create command failed due to wlm service unavailability. Will re-try after 30 seconds"
            sleep 30s
            continue
        elif [ $status -eq 0 ]; then
            echo -e "wlm cloud admin trust created successfully"
            break
        else
            echo -e "wlm cloud admin trust creation failed, re-trying"
            sleep 30s
            continue
        fi
done
