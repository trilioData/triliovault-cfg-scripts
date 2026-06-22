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

# Load modules from $CHARM_DIR/lib
sys.path.append("lib")

from charms.layer import basic

basic.bootstrap_charm_deps()
basic.init_config_states()

import charmhelpers.core.hookenv as hookenv

import charms.reactive as reactive

import charms_openstack.charm

# import the trilio_wlm module to get the charm definitions created.
import charm.openstack.trilio_wlm  # noqa


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
    if not ots_units:
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


def create_backup_targets(*args):
    """Create backup targets from an old 6.1 overlay bundle YAML file.

    Run on the trilio-wlm leader unit after upgrade to T4O 6.2 and
    after running unmount-old-backup-targets. Copy the bundle file to
    the unit with juju scp before calling this action.
    """
    import json
    import yaml

    if not hookenv.is_leader():
        hookenv.function_fail('Action must be run on the leader unit')
        return

    bundle_file = hookenv.action_get('bundle-file')
    if not os.path.isfile(bundle_file):
        hookenv.function_fail('File not found: {}'.format(bundle_file))
        return

    try:
        with open(bundle_file, 'r') as fh:
            bundle = yaml.safe_load(fh)
    except Exception as e:
        hookenv.function_fail('Failed to parse bundle YAML: {}'.format(e))
        return

    # Extract trilio-backup-targets from wlm or data-mover application options
    apps = bundle.get('applications', {})
    backup_targets_raw = None
    for app_name in ('trilio-wlm', 'trilio-data-mover'):
        opts = apps.get(app_name, {}).get('options', {})
        if 'trilio-backup-targets' in opts:
            backup_targets_raw = opts['trilio-backup-targets']
            break

    if backup_targets_raw is None:
        hookenv.function_fail(
            'trilio-backup-targets not found under '
            'applications.trilio-wlm.options or '
            'applications.trilio-data-mover.options in {}'.format(bundle_file)
        )
        return

    try:
        backup_targets = json.loads(backup_targets_raw)
    except (json.JSONDecodeError, TypeError) as e:
        hookenv.function_fail(
            'Failed to parse trilio-backup-targets JSON: {}'.format(e))
        return

    identity_service = reactive.endpoint_from_name('identity-service')
    if not identity_service or not identity_service.base_data_complete():
        hookenv.function_fail('identity-service relation not ready')
        return

    auth_url = '{}://{}:{}/v3'.format(
        identity_service.service_protocol(),
        identity_service.service_host(),
        identity_service.service_port(),
    )
    base_cmd = [
        'workloadmgr',
        '--os-username', identity_service.service_username(),
        '--os-password', identity_service.service_password(),
        '--os-auth-url', auth_url,
        '--os-user-domain-name', 'service_domain',
        '--os-project-domain-id', identity_service.service_domain_id(),
        '--os-project-id', identity_service.service_tenant_id(),
        '--os-project-name', identity_service.service_tenant(),
        '--os-region-name', hookenv.config('region'),
    ]

    results = []
    errors = []

    for bt in backup_targets:
        name = bt.get('backup-target-name', 'unnamed')
        bt_type = bt.get('backup-target-type', '').lower()
        cmd = base_cmd + ['backup-target-create',
                          '--backup-target-name', name,
                          '--backup-target-type', bt_type]
        if bt_type == 'nfs':
            cmd += ['--nfs-shares', bt.get('nfs-shares', '')]
            if bt.get('nfs-options'):
                cmd += ['--nfs-options', bt['nfs-options']]
        elif bt_type == 's3':
            cmd += [
                '--s3-access-key', bt.get('s3-access-key', ''),
                '--s3-secret-key', bt.get('s3-secret-key', ''),
                '--s3-region-name', bt.get('s3-region-name', ''),
                '--s3-bucket', bt.get('s3-bucket', ''),
                '--s3-type', bt.get('s3-type', 'amazon_s3'),
            ]
            if bt.get('s3-endpoint-url'):
                cmd += ['--s3-endpoint-url', bt['s3-endpoint-url']]
            if bt.get('s3-ssl-enabled') is not None:
                cmd += ['--s3-ssl-enabled', str(bt['s3-ssl-enabled']).lower()]
            if bt.get('s3-ssl-verify') is not None:
                cmd += ['--s3-ssl-verify', str(bt['s3-ssl-verify']).lower()]
            if bt.get('s3-ssl-ca_cert'):
                cmd += ['--s3-ssl-ca-cert', bt['s3-ssl-ca_cert']]
            if bt.get('s3-signature-version'):
                cmd += ['--s3-signature-version', bt['s3-signature-version']]
            if bt.get('s3-auth-version'):
                cmd += ['--s3-auth-version', bt['s3-auth-version']]
            if bt.get('s3-bucket-object-lock-enabled') is not None:
                cmd += ['--s3-bucket-object-lock-enabled',
                        str(bt['s3-bucket-object-lock-enabled']).lower()]
        else:
            errors.append('{}: unsupported type {}'.format(name, bt_type))
            continue

        try:
            subprocess.run(cmd, capture_output=True, text=True, check=True)
            results.append('{}: created'.format(name))
        except subprocess.CalledProcessError as e:
            errors.append('{}: failed — {}'.format(name, e.stderr.strip()))

    hookenv.action_set({'results': '\n'.join(results)})
    if errors:
        hookenv.function_fail('Errors:\n' + '\n'.join(errors))


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
        trilio_wlm_charm.run_trilio_upgrade(endpoints)
        trilio_wlm_charm._assess_status()


# Actions to function mapping, to allow for illegal python action names that
# can map to a python function.
ACTIONS = {
    "unmount-old-backup-targets": unmount_old_backup_targets,
    "create-backup-targets": create_backup_targets,
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
