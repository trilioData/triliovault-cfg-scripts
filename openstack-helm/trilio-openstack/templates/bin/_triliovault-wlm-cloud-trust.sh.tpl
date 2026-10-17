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

# The CA bundle must be wired up before the first openstack/workloadmgr call.
# keystone_openrc_env_vars only injects OS_CACERT when its useCA argument is
# true, and the job template computes that from $tlsSecret, which is always ""
# because of a scoped ':=' inside an if block -- so OS_CACERT never arrives and
# on a TLS cloud the very first `openstack` call below would die under set -e.
# Deriving it from the mounted bundle here is independent of that bug.
# manifests.certificates defaults to false, in which case the bundle is mounted
# but empty; passing an empty --os-cacert breaks verification against plain
# internal endpoints, so only use it when the file actually has content.
CACERT_OPT=""
if [ -s /etc/ssl/certs/openstack-ca-bundle.pem ]; then
    export OS_CACERT=/etc/ssl/certs/openstack-ca-bundle.pem
    CACERT_OPT="--os-cacert /etc/ssl/certs/openstack-ca-bundle.pem"
fi

export OS_PROJECT_ID=$(openstack project show -f value -c id "${OS_PROJECT_NAME}")

# --is_cloud_admin True is REQUIRED here and is not cosmetic. A cloud trust is
# stored with user_id='cloud_admin' (a literal string, not a UUID), while
# trust-list otherwise filters on context.user_id -- so a plain trust-list
# compares the admin's real UUID against 'cloud_admin' and always comes back
# empty, reporting "no trust" on a perfectly healthy deployment.
# Note the flag is spelled --is_cloud_admin on trust-list but --is_cloud_trust
# on trust-create; they are not interchangeable and each errors on the other's
# name.
# The grep -vE drops CLI chatter that the client prints on stdout ("Could not
# load '...'", "No module named ..."). Without it that noise is counted as a
# trust row, and a false positive here is the worse failure: the pre-check
# would skip creation and the job would report success with no trust.
trust_count() {
    workloadmgr $CACERT_OPT trust-list --is_cloud_admin True -f value -c TrustID 2>/dev/null \
      | grep -vE "Could not load '|No module named" \
      | grep -c '[^[:space:]]' || true
}

# This is a post-install,post-upgrade hook, so it re-runs on every helm upgrade,
# by which time the trust already exists.
existing=$(trust_count)
if [ "${existing:-0}" -gt 0 ]; then
    echo "Cloud admin trust already exists ($existing row(s)); nothing to do."
    exit 0
fi

for attempt in {1..10};
do
        echo -e "Attempting to create wlm-cloud admin trust, Attempt Number: $attempt"
        # The `if` wrapper is what makes the retry loop reachable. Under set -e
        # a bare `command_output=$(workloadmgr ...)` aborts the whole script the
        # moment workloadmgr exits non-zero, so the retry and the failure branch
        # below were dead code for every hard failure.
        if command_output=$(workloadmgr $CACERT_OPT trust-create --is_cloud_trust True admin 2>&1); then
            status=0
        else
            status=$?
        fi
        echo "Command output: $command_output"
        if echo "$command_output" | grep -qi "unavailable"; then
            echo -e "wlm cloud admin trust create command failed due to wlm service unavailability. Will re-try after 30 seconds"
            sleep 30s
            continue
        elif [ "$status" -eq 0 ]; then
            break
        else
            echo -e "wlm cloud admin trust creation failed, re-trying"
            sleep 30s
            continue
        fi
done

# THE EXIT CODE IS NOT EVIDENCE. `workloadmgr trust-create` returns 0 even when
# wlm-api answers HTTP 500 -- the cliff/cmd2 layer swallows it -- so reaching
# this point with status 0 does not mean a trust exists. The only proof is a
# non-empty trust-list.
count=$(trust_count)
if [ "${count:-0}" -gt 0 ]; then
    echo -e "wlm cloud admin trust created successfully ($count row(s))."
    exit 0
fi

echo -e "trust-list is empty -- the trust was NOT created, whatever the command reported."
echo -e "The Job will be retried (backoffLimit 1000, restartPolicy OnFailure)."
exit 1
