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
import subprocess
import sys

# Load modules from $CHARM_DIR/lib and $CHARM_DIR/reactive
sys.path.append("lib")
sys.path.append("reactive")

from charms.layer import basic

basic.bootstrap_charm_deps()
basic.init_config_states()

import charmhelpers.core.hookenv as hookenv
from charmhelpers.core import host

import charms.reactive as reactive

import charms_openstack.charm

# import the trilio_wlm module to get the charm definitions created.
import charm.openstack.trilio_wlm  # noqa

# import the reactive handlers module so the update-trilio action can
# explicitly re-run the WLM/DMS config render and DB migration — actions
# never go through the reactive hook-dispatch loop, so render_config()/
# init_db() would otherwise not run as part of an upgrade (TVAULT-7521,
# TVAULT-7522).
import trilio_wlm_handlers  # noqa

WLM_SERVICES = ['wlm-api', 'wlm-workloads', 'wlm-scheduler', 'wlm-cron']


def unmount_old_backup_targets(*args):
    """Lazy-unmount all mounts under /var/triliovault-mounts on this unit.

    Safe to run after upgrading to T4O 6.2 charms. Designed to run via:
    juju run trilio-wlm/* unmount-old-backup-targets
    """
    mount_base = '/var/triliovault-mounts'
    results = []
    errors = []

    # Stop and disable all tvault-object-store-*.service units so they cannot
    # remount targets while we are cleaning up
    list_result = subprocess.run(
        ['systemctl', 'list-units', '--all', '--plain', '--no-legend',
         'tvault-object-store-*.service'],
        capture_output=True, text=True)
    ots_units = [
        line.split()[0] for line in list_result.stdout.splitlines()
        if line.strip()
    ]
    for svc in ots_units:
        subprocess.run(['systemctl', 'stop', svc], capture_output=True)
        subprocess.run(['systemctl', 'disable', svc], capture_output=True)
        results.append('stopped and disabled: {}'.format(svc))

        # Remove the per-backup-target unit file too, not just stop+disable,
        # so a future mount of the same target starts from a clean slate
        # instead of racing a leftover unit definition (TVAULT-7523).
        show = subprocess.run(
            ['systemctl', 'show', svc, '-p', 'FragmentPath', '--value'],
            capture_output=True, text=True)
        unit_path = show.stdout.strip()
        if unit_path and os.path.exists(unit_path):
            try:
                os.remove(unit_path)
                results.append('removed unit file: {}'.format(unit_path))
            except OSError as e:
                errors.append('failed to remove unit file {}: {}'.format(unit_path, e))
    if ots_units:
        subprocess.run(['systemctl', 'daemon-reload'], capture_output=True)
    else:
        results.append('tvault-object-store: no units found')

    # Kill any s3vaultfuse processes left over from 6.1 (FUSE mounts)
    try:
        kill = subprocess.run(['pkill', '-f', 's3vaultfuse'],
                              capture_output=True)
        if kill.returncode == 0:
            results.append('s3vaultfuse: processes killed')
        elif kill.returncode == 1:
            results.append('s3vaultfuse: no processes running')
        else:
            errors.append('pkill s3vaultfuse returned: {}'.format(kill.returncode))
    except FileNotFoundError:
        errors.append('pkill not found')

    # Get all mounts with FSTYPE, sorted deepest-first to avoid busy-parent errors
    findmnt = subprocess.run(
        ['findmnt', '-rn', '-o', 'TARGET,FSTYPE'],
        capture_output=True, text=True)
    all_mounts = [
        line.split() for line in findmnt.stdout.splitlines()
        if mount_base in line and len(line.split()) >= 2
    ]
    all_mounts.sort(key=lambda x: x[0], reverse=True)

    if not all_mounts:
        results.append('no mounts found under {}'.format(mount_base))
    else:
        for parts in all_mounts:
            target, fstype = parts[0], parts[1]
            # NFS mounts need -f (force) in addition to -l (lazy)
            if fstype in ('nfs', 'nfs4'):
                cmd = ['umount', '-l', '-f', target]
            else:
                cmd = ['umount', '-l', target]
            try:
                subprocess.run(cmd, check=True)
                results.append('unmounted ({}): {}'.format(fstype, target))
            except subprocess.CalledProcessError as e:
                errors.append('umount failed for {}: {}'.format(target, e))

    hookenv.action_set({'results': '\n'.join(results)})
    if errors:
        hookenv.function_fail('Errors: ' + '; '.join(errors))


def create_cloud_admin_trust(*args):
    """Create trust relation between Trilio WLM and Cloud Admin
    """
    cloud_admin_password = hookenv.action_get("password")
    identity_service = reactive.endpoint_from_name(
        "identity-service"
    )
    with charms_openstack.charm.provide_charm_instance() as trilio_wlm_charm:
        trilio_wlm_charm.create_trust(identity_service, cloud_admin_password)
        trilio_wlm_charm._assess_status()


def create_license(*args):
    """Create license for operation of TrilioVault
    """
    identity_service = reactive.endpoint_from_name(
        "identity-service"
    )
    with charms_openstack.charm.provide_charm_instance() as trilio_wlm_charm:
        trilio_wlm_charm.create_license(identity_service)
        trilio_wlm_charm._assess_status()


def ghost_share(*args):
    """Ghost mount secondard TV deployment nfs-share
    """
    secondary_nfs_share = hookenv.action_get("nfs-shares")
    with charms_openstack.charm.provide_charm_instance() as trilio_wlm_charm:
        trilio_wlm_charm.ghost_nfs_share(secondary_nfs_share)
        trilio_wlm_charm._assess_status()


def update_trilio(*args):
    """Run setup after Trilio upgrade.
    """
    with charms_openstack.charm.provide_charm_instance() as trilio_wlm_charm:
        interfaces = ["shared-db", "amqp"]
        endpoints = [
            reactive.relations.endpoint_from_flag("{}.available".format(i))
            for i in interfaces]
        # identity-service is of type reactive.Endpoint rather than
        # reactive.RelationBase and needs a different method to instantiate it.
        endpoints.append(reactive.endpoint_from_name("identity-service"))

        # Stop wlm-* services before the package upgrade so nothing restarts
        # against a stale DB schema while run_trilio_upgrade() is installing
        # the new packages (TVAULT-7522).
        for svc in WLM_SERVICES:
            host.service('stop', svc)

        trilio_wlm_charm.run_trilio_upgrade(endpoints)

        # This action never goes through the reactive hook-dispatch loop, so
        # db_sync() and the WLM/DMS config render (normally triggered by
        # render_config()/init_db() on a later hook) must be run explicitly
        # here, in the correct order: migration before any service starts
        # (TVAULT-7522), and configs re-rendered with the correct
        # rabbitmq_url before trilio-dms-server/wlm-* come back up
        # (TVAULT-7521).
        trilio_wlm_charm.db_sync()
        trilio_wlm_handlers.render_wlm_and_dms_configs()

        for svc in WLM_SERVICES:
            host.service('start', svc)

        trilio_wlm_charm._assess_status()


# Actions to function mapping, to allow for illegal python action names that
# can map to a python function.
ACTIONS = {
    "unmount-old-backup-targets": unmount_old_backup_targets,
    "create-cloud-admin-trust": create_cloud_admin_trust,
    "create-license": create_license,
    "ghost-share": ghost_share,
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
