#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -ex
source /tmp/triliovault-cloudrc
export OS_PROJECT_ID=$(openstack project show -f value -c id "${OS_PROJECT_NAME}")

sleep 4m
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
