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
    openrc_file = hookenv.action_get('openrc-file')
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
    })

    # Overlay os_env with credentials from openrc-file if provided.
    # Use this when workloadmgr's internal Barbican user differs from the
    # charm's service user (403 Forbidden on secret retrieval).
    if openrc_file and os.path.isfile(openrc_file):
        with open(openrc_file) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith('export '):
                    line = line[7:]
                if '=' in line and not line.startswith('#'):
                    key, _, val = line.partition('=')
                    key = key.strip()
                    val = val.strip().strip('"').strip("'")
                    if key.startswith('OS_'):
                        os_env[key] = val

    # List existing backup targets from WLM DB
    try:
        list_proc = _run(
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
    cmd_log = []
    _SENSITIVE_FLAGS = frozenset({
        '--os-password', '--password', '--secret-key',
        '--access-key', '--payload',
    })

    def _run(cmd, **kwargs):
        safe = []
        mask_next = False
        for a in cmd:
            safe.append('[MASKED]' if mask_next else str(a))
            mask_next = str(a) in _SENSITIVE_FLAGS
        check = kwargs.pop('check', False)
        proc = subprocess.run(cmd, **kwargs)
        cmd_log.append(
            'CMD: {}\nRC: {}\nSTDOUT: {}\nSTDERR: {}'.format(
                ' '.join(safe),
                proc.returncode,
                (proc.stdout or '').strip(),
                (proc.stderr or '').strip(),
            )
        )
        if check and proc.returncode != 0:
            raise subprocess.CalledProcessError(
                proc.returncode, cmd, proc.stdout, proc.stderr)
        return proc

    for idx, bt in enumerate(backup_targets):
        name = bt.get('backup-target-name', 'unnamed')
        bt_type = bt.get('backup-target-type', '').lower()

        if bt_type == 'nfs':
            nfs_shares = bt.get('nfs-shares', '')
            existing_id = find_existing_id('nfs', nfs_shares)
            if existing_id:
                try:
                    _run(
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
            if idx == 0:
                cmd.append('--default')
            try:
                _run(cmd, capture_output=True, text=True, check=True)
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
                    _run(
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
                filesystem_export = '{}/{}'.format(parsed.hostname, bucket)
            else:
                filesystem_export = bucket

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
                dms_cmd.append('--ssl' if ssl_enabled else '--no-ssl')
                if ssl_verify and cert_path:
                    dms_cmd += ['--ssl-verify', '--ssl-cert', cert_path]
                else:
                    dms_cmd.append('--no-ssl-verify')

                try:
                    _run(dms_cmd, capture_output=True,
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
                    _run(
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

                store_proc = _run(
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
                # case. Use keystoneauth1 (available in charm env) to look
                # up the real public Barbican endpoint from the service
                # catalog, avoiding subprocess/SSL/environment issues.
                parsed_href = urlparse(secret_href)
                if not parsed_href.hostname or \
                        parsed_href.hostname.lower() == 'none':
                    try:
                        from keystoneauth1.identity import v3 as ks_v3
                        from keystoneauth1 import session as ks_session
                        cacert = os_env.get('OS_CACERT') or False
                        ks_auth = ks_v3.Password(
                            auth_url=auth_url,
                            username=identity_service.service_username(),
                            password=identity_service.service_password(),
                            user_domain_name='service_domain',
                            project_id=identity_service.service_tenant_id(),
                        )
                        ks_sess = ks_session.Session(
                            auth=ks_auth, verify=cacert)
                        barbican_endpoint = ks_sess.get_endpoint(
                            service_type='key-manager', interface='public')
                        if barbican_endpoint:
                            secret_uuid = secret_href.rstrip('/').split('/')[-1]
                            base = barbican_endpoint.rstrip('/')
                            if not base.endswith('/v1'):
                                base += '/v1'
                            secret_href = '{}/secrets/{}'.format(
                                base, secret_uuid)
                    except Exception as e:
                        errors.append(
                            '{}: href normalization failed — {}'.format(
                                name, e))

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
                if endpoint_url:
                    cmd += ['--s3-endpoint-url', endpoint_url]
                if idx == 0:
                    cmd.append('--default')

                proc = _run(cmd, capture_output=True, text=True)
                output = (proc.stdout + proc.stderr).strip()
                if proc.returncode != 0 or \
                        'ERROR' in proc.stdout or 'Error:' in proc.stdout:
                    errors.append('{}: create failed — {}'.format(
                        name, output))
                else:
                    results.append('{}: created (s3, secret-ref={})'.format(
                        name, secret_href))

            finally:
                for path in [secret_json_path, cert_path]:
                    if path:
                        try:
                            os.unlink(path)
                        except OSError:
                            pass

        else:
            errors.append('{}: unsupported type {}'.format(name, bt_type))

    # -----------------------------------------------------------------------
    # Verification: confirm each created target appears in backup-target-list
    # and each created secret appears in openstack secret list.
    # -----------------------------------------------------------------------
    created_names = set()
    for r in results:
        created_names.add(r.split(':')[0].strip())

    if created_names:
        # Verify backup targets
        try:
            bt_list_proc = _run(
                wlm_base + ['backup-target-list', '--format', 'json'],
                capture_output=True, text=True)
            bt_list = (json.loads(bt_list_proc.stdout)
                       if bt_list_proc.stdout.strip() else [])
            bt_names_in_wlm = {t.get('Name', t.get('BTT Name', ''))
                                for t in bt_list}
            for name in created_names:
                if name not in bt_names_in_wlm:
                    errors.append(
                        '{}: not found in backup-target-list after creation'
                        ' — WLM may have rejected it'.format(name))
        except Exception as e:
            errors.append('backup-target-list verification failed: {}'.format(e))

        # Verify secrets
        try:
            sec_list_proc = _run(
                ['openstack', 'secret', 'list', '-f', 'json'],
                capture_output=True, text=True, env=os_env)
            sec_list = (json.loads(sec_list_proc.stdout)
                        if sec_list_proc.stdout.strip() else [])
            sec_names_in_barbican = {
                s.get('Name', '') for s in sec_list}
            for name in created_names:
                secret_name = 'secret-key-{}'.format(name)
                if secret_name not in sec_names_in_barbican:
                    errors.append(
                        '{}: secret "{}" not found in Barbican after'
                        ' creation'.format(name, secret_name))
        except Exception as e:
            errors.append('secret list verification failed: {}'.format(e))

    log_path = '/tmp/trilio_create_bt_cmdlog.txt'
    with open(log_path, 'w') as _lf:
        _lf.write('\n\n'.join(cmd_log))
    hookenv.action_set({
        'results': '\n'.join(results),
        'cmd-log-file': log_path,
    })
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
