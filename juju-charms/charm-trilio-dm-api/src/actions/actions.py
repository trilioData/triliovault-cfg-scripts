#!/usr/local/sbin/charm-env python3
# Copyright 2018,2020 Canonical Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import sys

# Load modules from $CHARM_DIR/lib and $CHARM_DIR/reactive
sys.path.append("lib")
sys.path.append("reactive")

from charms.layer import basic

basic.bootstrap_charm_deps()
basic.init_config_states()

import charmhelpers.core.hookenv as hookenv

import charms.reactive as reactive

import charms_openstack.charm

# import the trilio module to get the charm definitions created.
import charm.openstack.dmapi  # noqa

# import the reactive handlers module so the update-trilio action can
# explicitly re-render the DMS client config — actions never go through the
# reactive hook-dispatch loop, so render_config() would otherwise not run as
# part of an upgrade (TVAULT-7521).
import dmapi_handlers  # noqa


def update_trilio(*args):
    """Run setup after Trilio upgrade.
    """
    with charms_openstack.charm.provide_charm_instance() as trilio_charm:
        interfaces = ["shared-db", "amqp"]
        endpoints = [
            reactive.relations.endpoint_from_flag("{}.available".format(i))
            for i in interfaces]
        # identity-service is of type reactive.Endpoint rather than
        # reactive.RelationBase and needs a different method to instantiate it.
        endpoints.append(reactive.endpoint_from_name("identity-service"))
        trilio_charm.run_trilio_upgrade(endpoints)

        # This action never goes through the reactive hook-dispatch loop, so
        # the DMS client config render (normally triggered by render_config()
        # on a later hook) must be run explicitly here, with the correct
        # rabbitmq_url, before trilio-dms-server settles (TVAULT-7521).
        # render_dmapi_and_dms_configs() writes client.conf unconditionally,
        # including the workloadmgr db_url once shared-db has supplied it, so
        # no separate render_dms_client_config() call is needed here.
        dmapi_handlers.render_dmapi_and_dms_configs()

        trilio_charm._assess_status()


# Actions to function mapping, to allow for illegal python action names that
# can map to a python function.
ACTIONS = {
    "update-trilio": update_trilio,
}


def main(args):
    hookenv._run_atstart()
    action_name = os.path.basename(args[0])
    try:
        action = ACTIONS[action_name]
    except KeyError:
        return "Action %s undefined" % action_name
    else:
        try:
            action(args)
        except Exception as e:
            hookenv.function_fail(str(e))
    hookenv._run_atexit()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
