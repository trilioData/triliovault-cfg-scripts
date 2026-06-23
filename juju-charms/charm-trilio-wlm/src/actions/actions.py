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
    """Create backup targets from a previous-release overlay bundle YAML file.

    For each entry in trilio-backup-targets:
    - If a matching target already exists in WLM DB (matched by endpoint),
      it is deleted first then recreated fresh.
    - NFS targets are created directly via workloadmgr backup-target-create.
    - S3 targets require a Barbican secret (mandatory in T4O 6.2). The action
      uses trilio-dms-cli to build the DMS secret payload, stores it in
      Barbican via openstack secret store, then passes --secret-ref to
      workloadmgr backup-target-create.
    """
    import json
    import tempfile
    import yaml
    from urllib.parse import urlparse

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
    wlm_base = [
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

    # openstack CLI env for Barbican (secret store)
    os_env = os.environ.copy()
    os_env.update({
        'OS_USERNAME': identity_service.service_username(),
        'OS_PASSWORD': identity_service.service_password(),
        'OS_AUTH_URL': auth_url,
        'OS_USER_DOMAIN_NAME': 'service_domain',
        'OS_PROJECT_DOMAIN_ID': identity_service.service_domain_id(),
        'OS_PROJECT_ID': identity_service.service_tenant_id(),
        'OS_PROJECT_NAME': identity_service.service_tenant(),
        'OS_REGION_NAME': hookenv.config('region'),
        'OS_IDENTITY_API_VERSION': '3',
        'OS_INSECURE': '1',
    })

    # List existing backup targets from WLM DB
    try:
        list_proc = subprocess.run(
            wlm_base + ['backup-target-list', '--format', 'json'],
            capture_output=True, text=True, check=True)
        existing_targets = (json.loads(list_proc.stdout)
                            if list_proc.stdout.strip() else [])
    except subprocess.CalledProcessError as e:
        hookenv.function_fail(
            'Failed to list existing backup targets: {}'.format(e.stderr.strip()))
        return
    except json.JSONDecodeError:
        existing_targets = []

    def find_existing_id(bt_type, endpoint_hint):
        for t in existing_targets:
            if t.get('Type', '').lower() != bt_type:
                continue
            if endpoint_hint in t.get('Backend Endpoint', ''):
                return t.get('ID')
        return None

    results = []
    errors = []

    for bt in backup_targets:
        name = bt.get('backup-target-name', 'unnamed')
        bt_type = bt.get('backup-target-type', '').lower()

        if bt_type == 'nfs':
            nfs_shares = bt.get('nfs-shares', '')
            existing_id = find_existing_id('nfs', nfs_shares)
            if existing_id:
                try:
                    subprocess.run(
                        wlm_base + ['backup-target-delete', existing_id],
                        capture_output=True, text=True, check=True)
                    results.append('{}: deleted existing (id={})'.format(
                        name, existing_id))
                except subprocess.CalledProcessError as e:
                    errors.append('{}: delete failed — {}'.format(
                        name, e.stderr.strip()))
                    continue

            cmd = wlm_base + [
                'backup-target-create',
                '--btt-name', name,
                '--type', 'nfs',
                '--filesystem-export', nfs_shares,
            ]
            if bt.get('nfs-options'):
                cmd += ['--nfs-mount-opts', bt['nfs-options']]
            try:
                subprocess.run(cmd, capture_output=True, text=True, check=True)
                results.append('{}: created (nfs)'.format(name))
            except subprocess.CalledProcessError as e:
                errors.append('{}: create failed — {}'.format(
                    name, e.stderr.strip()))

        elif bt_type == 's3':
            bucket = bt.get('s3-bucket', '')
            endpoint_url = bt.get('s3-endpoint-url', '')
            access_key = bt.get('s3-access-key', '')
            secret_key = bt.get('s3-secret-key', '')
            s3_type = bt.get('s3-type', 'amazon_s3')
            ssl_enabled = bt.get('s3-ssl-enabled', False)
            ssl_verify = bt.get('s3-ssl-verify', False)
            ssl_ca_cert = bt.get('s3-ssl-ca_cert', '')

            existing_id = find_existing_id('s3', bucket)
            if existing_id:
                try:
                    subprocess.run(
                        wlm_base + ['backup-target-delete', existing_id],
                        capture_output=True, text=True, check=True)
                    results.append('{}: deleted existing (id={})'.format(
                        name, existing_id))
                except subprocess.CalledProcessError as e:
                    errors.append('{}: delete failed — {}'.format(
                        name, e.stderr.strip()))
                    continue

            # filesystem-export format required by trilio-dms-cli:
            #   S3-compatible endpoint: s3server:<hostname>/<bucket>
            #   AWS S3 (no endpoint):   s3server:/<bucket>
            if endpoint_url:
                parsed = urlparse(endpoint_url)
                filesystem_export = 's3server:{}/{}'.format(parsed.hostname, bucket)
            else:
                filesystem_export = 's3server:/{}'.format(bucket)

            secret_json_path = None
            cert_path = None
            try:
                with tempfile.NamedTemporaryFile(
                        suffix='.json', delete=False) as tmp:
                    secret_json_path = tmp.name

                if ssl_ca_cert and ssl_verify:
                    with tempfile.NamedTemporaryFile(
                            suffix='.pem', delete=False, mode='w') as cert_tmp:
                        cert_tmp.write(ssl_ca_cert)
                        cert_path = cert_tmp.name

                dms_cmd = [
                    'trilio-dms-cli', 'secret-payload', 'create',
                    '--access-key', access_key,
                    '--secret-key', secret_key,
                    '--bucket', bucket,
                    '--filesystem-export', filesystem_export,
                    '-o', secret_json_path,
                ]
                if endpoint_url:
                    dms_cmd += ['--endpoint-url', endpoint_url]
                if ssl_enabled:
                    dms_cmd.append('--ssl')
                if ssl_verify:
                    dms_cmd.append('--ssl-verify')
                if cert_path:
                    dms_cmd += ['--ssl-cert', cert_path]

                try:
                    subprocess.run(dms_cmd, capture_output=True,
                                   text=True, check=True)
                except subprocess.CalledProcessError as e:
                    errors.append('{}: trilio-dms-cli create failed — {}'.format(
                        name, e.stderr.strip()))
                    continue
                except FileNotFoundError:
                    errors.append(
                        '{}: trilio-dms-cli not found on this unit'.format(name))
                    continue

                try:
                    subprocess.run(
                        ['trilio-dms-cli', 'secret-payload', 'validate',
                         secret_json_path],
                        capture_output=True, text=True, check=True)
                except subprocess.CalledProcessError as e:
                    errors.append(
                        '{}: DMS secret validation failed — {}'.format(
                            name, e.stderr.strip()))
                    continue

                with open(secret_json_path, 'r') as f:
                    secret_payload = f.read().strip()

                store_proc = subprocess.run(
                    ['openstack', 'secret', 'store',
                     '--name', 'secret-key-{}'.format(name),
                     '--payload', secret_payload,
                     '-f', 'json'],
                    capture_output=True, text=True, env=os_env)
                if store_proc.returncode != 0:
                    errors.append(
                        '{}: openstack secret store failed — {}'.format(
                            name, store_proc.stderr.strip()))
                    continue

                try:
                    store_data = json.loads(store_proc.stdout)
                    if isinstance(store_data, list):
                        store_data = store_data[0] if store_data else {}
                    secret_href = (store_data.get('secret_href')
                                   or store_data.get('Secret href')
                                   or store_data.get('href', ''))
                except (json.JSONDecodeError, IndexError):
                    errors.append(
                        '{}: failed to parse Barbican response'.format(name))
                    continue

                if not secret_href:
                    errors.append(
                        '{}: empty secret href from Barbican'.format(name))
                    continue

                # Normalize the href when Barbican's host_href is not
                # configured — it returns https://None:<port>/... in that
                # case. Extract the UUID and rebuild using the public endpoint.
                parsed_href = urlparse(secret_href)
                if not parsed_href.hostname or \
                        parsed_href.hostname.lower() == 'none':
                    ep_proc = subprocess.run(
                        ['openstack', 'endpoint', 'list',
                         '--service', 'key-manager',
                         '--interface', 'public', '-f', 'json'],
                        capture_output=True, text=True, env=os_env)
                    if ep_proc.returncode == 0:
                        try:
                            eps = json.loads(ep_proc.stdout)
                            if eps:
                                barbican_base = eps[0]['URL'].rstrip('/')
                                secret_uuid = secret_href.rstrip('/').split('/')[-1]
                                if not barbican_base.endswith('/v1'):
                                    barbican_base += '/v1'
                                secret_href = '{}/secrets/{}'.format(
                                    barbican_base, secret_uuid)
                        except (json.JSONDecodeError, IndexError, KeyError):
                            pass

                # In T4O 6.2, all S3 connection details (endpoint, SSL,
                # credentials) are stored in the Barbican secret. Only
                # --btt-name, --type, --s3-bucket, and --secret-ref are
                # passed to backup-target-create.
                cmd = wlm_base + [
                    'backup-target-create',
                    '--btt-name', name,
                    '--type', 's3',
                    '--s3-bucket', bucket,
                    '--secret-ref', secret_href,
                ]

                try:
                    subprocess.run(cmd, capture_output=True,
                                   text=True, check=True)
                    results.append('{}: created (s3, secret-ref={})'.format(
                        name, secret_href))
                except subprocess.CalledProcessError as e:
                    errors.append('{}: create failed — {}'.format(
                        name, e.stderr.strip()))

            finally:
                for path in [secret_json_path, cert_path]:
                    if path:
                        try:
                            os.unlink(path)
                        except OSError:
                            pass

        else:
            errors.append('{}: unsupported type {}'.format(name, bt_type))

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
