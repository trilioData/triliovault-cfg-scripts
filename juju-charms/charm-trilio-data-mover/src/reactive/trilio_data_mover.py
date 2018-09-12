import os
import re
import netaddr
import configparser
import time

from subprocess import (
    check_output,
    call,
)

from charms.reactive import (
    when,
    when_not,
    set_flag,
    hook,
    remove_state,
    set_state,
)
from charmhelpers.core.hookenv import (
    status_set,
    config,
    log,
)
from charmhelpers.contrib.python.packages import (
    pip_install,
)

from charmhelpers.core.host import (
    service_restart,
    service_stop,
    service_running,
    write_file,
    mount,
    umount,
    mounts,
    add_user_to_group,
    symlink,
    mkdir,
    chownr,
)

from charmhelpers.fetch.archiveurl import (
    ArchiveUrlFetchHandler,
)

VALID_BACKUP_TARGETS = [
    'nfs',
    's3'
]

VALID_S3_TYPES = [
    'Amazon'
]


def pip_list(venv):
    """
    Charmhelpers do not have any option to list out installed
    pip packages in a virtual environment, hence this module.
    """
    pip_cmd = '{}/bin/pip'.format(venv)
    return check_output([pip_cmd, 'list']).decode('utf-8').split('\n')


def pip_uninstall(pkg, venv):
    """
    Charmhelpers do not have any option to un-install
    pip packages in a virtual environment, hence this module.
    """
    pip_cmd = '{}/bin/pip'.format(venv)
    if not call([pip_cmd, 'uninstall', '-y', pkg]):
        return True
    return False


def get_new_version(pkg):
    """
    Get the latest version available on the TrilioVault node.
    """
    tv_ip = config('triliovault-ip')
    tv_port = 8081

    curl_cmd = 'curl -s http://{}:{}/packages/'.format(tv_ip, tv_port).split()
    pkgs = check_output(curl_cmd)
    new_ver = re.search(
        r'packages/{}-\s*([\d.]+)'.format(pkg),
        pkgs.decode('utf-8')).group(1)[:-1]

    return new_ver


def check_presence(tv_file):
    """
    Just a wrpper of 'ls' command
    """
    if os.system('ls {}'.format(tv_file)):
        return False
    return True


def validate_nfs():
    """
    Validate the nfs mount device
    """
    usr = config('tvault-datamover-ext-usr')
    grp = config('tvault-datamover-ext-group')
    data_dir = config('tv-data-dir')
    device = config('nfs-shares')

    # Ensure mount directory exists
    mkdir(data_dir, owner=usr, group=grp)

    # check for mountable device
    if not mount(device, data_dir, filesystem='nfs'):
        log("Unable to mount, please enter valid mount device")
        return False
    log("Device mounted successfully")
    umount(data_dir)
    log("Device unmounted successfully")
    return True


def validate_s3():
    """
    Validate S3 backup target
    """
    s3_type = config('tv-s3-type')
    s3_access_key = config('tv-s3-access-key')
    s3_secret_key = config('tv-s3-secret-key')

    if s3_type not in VALID_S3_TYPES:
        log("{} S3 type not supported".format(s3_type))
        return False

    if s3_type == 'Amazon':
        if not s3_access_key or not s3_secret_key:
            log("Empty values provided!")
            return False
        if not call(['python', 'files/trilio/validate_s3.py',
                     s3_access_key, s3_secret_key]):
            log("Valid S3 credentials")
            return True
        log("Invalid S3 credentials")
    return False


def validate_backup():
    """
    Forwards to the respective modules accroding to the type of backup target.
    """
    bkp_type = config('backup-target-type')

    if bkp_type not in VALID_BACKUP_TARGETS:
        log("Not a valid backup target type")
        return False
    if bkp_type == 'nfs':
        return validate_nfs()
    elif bkp_type == 's3':
        return validate_s3()


def add_users():
    """
    Adding passwordless sudo access to nova user and adding to required groups
    """
    usr = config('tvault-datamover-ext-usr')
    path = '/etc/sudoers.d/tvault-nova'
    source = '/usr/lib'
    destination = '/usr/lib64'
    content = '{} ALL=(ALL) NOPASSWD: ALL'.format(usr)
    try:
        write_file(path, content, owner='root', group='root', perms=292)

        # Adding nova user to system groups
        add_user_to_group(usr, 'kvm')
        add_user_to_group(usr, 'disk')

        # create symlink /usr/lib64/
        symlink(source, destination)
    except Exception as e:
        log("Failed while adding user with msg: {}".format(e))
        return False

    return True


def create_virt_env():
    """
    Checks if latest version is installed or else imports the new virtual env
    And installs the Datamover package.
    """
    usr = config('tvault-datamover-ext-usr')
    grp = config('tvault-datamover-ext-group')
    path = config('tvault-datamover-virtenv')
    venv_path = config('tvault-datamover-virtenv-path')
    tv_ip = config('triliovault-ip')
    dm_ver = None
    # create virtenv dir(/home/tvault) if it does not exist
    mkdir(path, owner=usr, group=grp, perms=765, force=False)

    # check existance of already installed virtual env
    ''' TODO: Need to validate this section
    venv_chk = check_presence(venv_path)
    if venv_chk: # if path exists
        pl = pip_list(venv_path)
        dm_pkg = [l for l in pl if 'tvault-contego' in l]
        if dm_pkg:
            dm_ver = dm_pkg[0].split('(')[1].split(')')[0]
    '''
    latest_dm_ver = get_new_version('tvault-contego')
    if dm_ver == latest_dm_ver:
        log("Latest TrilioVault DataMover package is already installed,"
            " exiting")
        return True

    # Create virtual environment for DataMover
    handler = ArchiveUrlFetchHandler()
    try:
        # remove old venv if it exists
        os.system('rm -rf {}'.format(venv_path))
        venv_src = 'http://{}:8081/packages/queens_ubuntu'\
                   '/tvault-contego-virtenv.tar.gz'.format(tv_ip)
        venv_dest = path
        handler.install(venv_src, venv_dest)
        log("Virtual Environment installed successfully")
    except Exception as e:
        log("Failed to install Virtual Environment")
        return False

    # Get dependent libraries paths
    try:
        cmd = ['/usr/bin/python', 'files/trilio/get_pkgs.py']
        sym_link_paths = check_output(cmd).decode('utf-8').strip().split('\n')
    except Exception as e:
        log("Failed to get the dependent packages--{}".format(e))
        return False

    # Install TrilioVault Datamover package
    if not install_plugin(tv_ip, latest_dm_ver, venv_path):
        return False

    # Create symlinks of the dependent libraries
    venv_pkg_path = '{}/lib/python2.7/site-packages/'.format(venv_path)
    os.system('rm -rf {}/cryptography'.format(venv_pkg_path))
    os.system('rm -rf {}/cffi'.format(venv_pkg_path))

    symlink(sym_link_paths[0], '{}/cryptography'.format(venv_pkg_path))
    symlink(sym_link_paths[2], '{}/cffi'.format(venv_pkg_path))

    os.system(
        'cp {} {}/libvirtmod.so'.format(sym_link_paths[1], venv_pkg_path))
    os.system(
        'cp {} {}/_cffi_backend.so'.format(sym_link_paths[3], venv_pkg_path))

    # change virtenv dir(/home/tvault) users to nova
    chownr(path, usr, grp)

    return True


def ensure_files():
    """
    Ensures all the required files or directories
    are present before it starts the datamover service.
    """
    usr = config('tvault-datamover-ext-usr')
    grp = config('tvault-datamover-ext-group')
    venv_path = config('tvault-datamover-virtenv-path')
    dm_bin = '{}/bin/tvault-contego'.format(venv_path)
    log_path = '/var/log/nova'
    conf_path = '/etc/tvault-contego'

    # Creates log directory if doesn't exists
    mkdir(log_path, owner=usr, group=grp, perms=765, force=False)

    if not check_presence(dm_bin):
        log("TrilioVault Datamover binary is not present")
        return False

    # Creates conf directory if doesn't exists
    mkdir(conf_path, owner=usr, group=grp, perms=765, force=False)

    return True


def create_conf():
    """
    Creates datamover config file.
    """
    nfs_share = config('nfs-shares')
    nfs_options = config('nfs-options')
    tv_data_dir_old = config('tv-data-dir-old')
    tv_data_dir = config('tv-data-dir')
    bkp_type = config('backup-target-type')

    tv_config = configparser.RawConfigParser()
    if bkp_type == 'nfs':
        tv_config.set('DEFAULT', 'vault_storage_nfs_export', nfs_share)
        tv_config.set('DEFAULT', 'vault_storage_nfs_options', nfs_options)
    elif bkp_type == 's3':
        tv_config.set('DEFAULT', 'vault_storage_nfs_export', 'TrilioVault')
        tv_config.set('DEFAULT', 'vault_s3_auth_version', 'DEFAULT')
        tv_config.set('DEFAULT', 'vault_s3_access_key_id',
                      config('tv-s3-access-key'))
        tv_config.set('DEFAULT', 'vault_s3_secret_access_key',
                      config('tv-s3-secret-key'))
        tv_config.set('DEFAULT', 'vault_s3_region_name',
                      config('tv-s3-region-name'))
        tv_config.set('DEFAULT', 'vault_s3_bucket', config('tv-s3-bucket'))
    tv_config.set('DEFAULT', 'vault_storage_type', bkp_type)
    tv_config.set('DEFAULT', 'vault_data_directory_old', tv_data_dir_old)
    tv_config.set('DEFAULT', 'vault_data_directory', tv_data_dir)
    tv_config.set('DEFAULT', 'log_file', '/var/log/nova/tvault-contego.log')
    tv_config.set('DEFAULT', 'debug', False)
    tv_config.set('DEFAULT', 'verbose', True)
    tv_config.set('DEFAULT', 'max_uploads_pending', 3)
    tv_config.set('DEFAULT', 'max_commit_pending', 3)

    with open(config('tv-datamover-conf'), 'w') as cf:
        tv_config.write(cf)

    return True


def ensure_data_dir():
    """
    Ensures all the required directories are present
    and have appropriate permissions.
    """
    usr = config('tvault-datamover-ext-usr')
    grp = config('tvault-datamover-ext-group')
    data_dir = config('tv-data-dir')
    data_dir_old = config('tv-data-dir-old')
    # ensure that data_dir is present
    mkdir(data_dir, owner=usr, group=grp)
    # remove data_dir_old
    os.system('rm -rf {}'.format(data_dir_old))
    # recreate the data_dir_old
    mkdir(data_dir_old, owner=usr, group=grp)

    # create logrotate file for tvault-contego.log
    src = 'files/trilio/tvault-contego'
    dest = '/etc/logrotate.d/tvault-contego'
    os.system('cp {} {}'.format(src, dest))

    return True


def create_service_file():
    """
    Creates datamover service file.
    """
    usr = config('tvault-datamover-ext-usr')
    grp = config('tvault-datamover-ext-group')
    venv_path = config('tvault-datamover-virtenv-path')
    cmd = ['{}/bin/python'.format(venv_path), 'files/trilio/get_nova_conf.py']

    config_files = check_output(cmd).decode('utf-8').split('\n')[0]
    config_files = '{} --config-file={}'.format(
        config_files, config('tv-datamover-conf'))
    if check_presence('/etc/nova/nova.conf.d'):
        config_files = '{} --config-dir=/etc/nova/nova.conf.d'.format(
            config_files)

    # create service file
    exec_start = '{}/bin/python {}/bin/tvault-contego {}\
                 '.format(venv_path, venv_path, config_files)
    tv_config = configparser.RawConfigParser()
    tv_config.optionxform = str
    tv_config.add_section('Unit')
    tv_config.add_section('Service')
    tv_config.add_section('Install')
    tv_config.set('Unit', 'Description', 'TrilioVault DataMover')
    tv_config.set('Unit', 'After', 'openstack-nova-compute.service')
    tv_config.set('Service', 'User', usr)
    tv_config.set('Service', 'Group', grp)
    tv_config.set('Service', 'Type', 'simple')
    tv_config.set('Service', 'ExecStart', exec_start)
    tv_config.set('Service', 'TimeoutStopSec', 20)
    tv_config.set('Service', 'KillMode', 'process')
    tv_config.set('Service', 'Restart', 'on-failure')
    tv_config.set('Install', 'WantedBy', 'multi-user.target')

    with open('/etc/systemd/system/tvault-contego.service', 'w') as cf:
        tv_config.write(cf)

    return True


def create_object_storage_service():
    """
    Creates object storage service file.
    """
    venv_path = config('tvault-datamover-virtenv-path')
    storage_path = '{}/lib/python2.7/site-packages/contego/nova/'\
                   'extension/driver/s3vaultfuse.py'.format(venv_path)
    config_file = config('tv-datamover-conf')
    # create service file
    exec_start = '{}/bin/python {} --config-file={}'\
                 .format(venv_path, storage_path, config_file)
    tv_config = configparser.RawConfigParser()
    tv_config.optionxform = str
    tv_config.add_section('Unit')
    tv_config.add_section('Service')
    tv_config.add_section('Install')
    tv_config.set('Unit', 'Description', 'TrilioVault Object Store')
    tv_config.set('Unit', 'After', 'tvault-contego.service')
    # TODO : make the user and group 'nova'
    tv_config.set('Service', 'User', 'root')
    tv_config.set('Service', 'Group', 'root')
    tv_config.set('Service', 'Type', 'simple')
    tv_config.set('Service', 'ExecStart', exec_start)
    tv_config.set('Service', 'TimeoutStopSec', 20)
    tv_config.set('Service', 'KillMode', 'process')
    tv_config.set('Service', 'Restart', 'on-failure')
    tv_config.set('Install', 'WantedBy', 'multi-user.target')

    with open('/etc/systemd/system/tvault-object-store.service', 'w') as cf:
        tv_config.write(cf)

    return True


def validate_ip(ip):
    """
    Validate triliovault_ip provided by the user
    triliovault_ip should not be blank
    triliovault_ip should have a valid IP address and reachable
    """
    if ip.strip():
        # Not blank
        if netaddr.valid_ipv4(ip):
            # Valid IP address, check if it's reachable
            if os.system("ping -c 1 " + ip):
                return False
            return True
        else:
            # Invalid IP address
            return False
    return False


def install_plugin(ip, ver, venv):
    """
    Install TrilioVault DataMover package
    """
    pkg = 'http://{}:8081/packages/tvault-contego-{}.tar.gz'.format(ip, ver)

    try:
        pip_install(pkg, venv=venv, options="--no-deps")
        log("TrilioVault DataMover package installation passed")

        status_set('maintenance', 'Starting...')
        return True
    except Exception as e:
        # Datamover package installation failed
        log("TrilioVault Datamover package installation failed")
        log("With exception --{}".format(e))
        return False


def uninstall_plugin():
    """
    Uninstall TrilioVault DataMover packages
    """
    retry_count = 0
    bkp_type = config('backup-target-type')
    try:
        path = config('tvault-datamover-virtenv')
        service_stop('tvault-contego')
        os.system('sudo systemctl disable tvault-contego')
        os.system('rm -rf /etc/systemd/system/tvault-contego.service')
        if bkp_type == 's3':
            service_stop('tvault-object-store')
            os.system('systemctl disable tvault-object-store')
            os.system('rm -rf /etc/systemd/system/tvault-object-store.service')
        os.system('sudo systemctl daemon-reload')
        os.system('rm -rf {}'.format(path))
        os.system('rm -rf /etc/logrotate.d/tvault-contego')
        os.system('rm -rf {}'.format(config('tv-datamover-conf')))
        os.system('rm -rf /var/log/nova/tvault-contego.log')
        # Get the mount points and un-mount tvault's mount points.
        mount_points = mounts()
        sorted_list = [mp[0] for mp in mount_points
                       if config('tv-data-dir') in mp[0]]
        # stopping the tvault-object-store service may take time
        while service_running('tvault-object-store') and retry_count < 3:
            log('Waiting for tvault-object-store service to stop')
            retry_count += 1
            time.sleep(5)

        for sl in sorted_list:
            umount(sl)

        log("TrilioVault Datamover package uninstalled successfully")
        return True
    except Exception as e:
        # package uninstallation failed
        log("TrilioVault Datamover package un-installation failed:"
            " {}".format(e))
        return False


@when_not('tvault-contego.installed')
def install_tvault_contego_plugin():

    status_set('maintenance', 'Installing...')

    # Read config parameters TrilioVault IP, backup target
    tv_ip = config('triliovault-ip')
    bkp_type = config('backup-target-type')

    # Validate triliovault_ip
    if not validate_ip(tv_ip):
        # IP address is invalid
        # Set status as blocked and return
        status_set(
            'blocked',
            'Invalid IP address, please provide correct IP address')
        return

    # Valildate backup target
    if not validate_backup():
        log("Failed while validating backup")
        status_set(
            'blocked',
            'Invalid Backup target type, please provide valid info')
        return

    # Proceed as triliovault_ip Address is valid
    if not add_users():
        log("Failed while adding Users")
        status_set('blocked', 'Failed while adding Users')
        return

    if not create_virt_env():
        log("Failed while Creating Virtual Env")
        status_set('blocked', 'Failed while Creating Virtual Env')
        return

    if not ensure_files():
        log("Failed while ensuring files")
        status_set('blocked', 'Failed while ensuring files')
        return

    if not create_conf():
        log("Failed while creating conf files")
        status_set('blocked', 'Failed while creating conf files')
        return

    if not ensure_data_dir():
        log("Failed while ensuring datat directories")
        status_set('blocked', 'Failed while ensuring datat directories')
        return

    if not create_service_file():
        log("Failed while creating DataMover service file")
        status_set('blocked', 'Failed while creating DataMover service file')
        return

    if bkp_type == 's3' and not create_object_storage_service():
        log("Failed while creating Object Store service file")
        status_set('blocked', 'Failed while creating ObjectStore service file')
        return

    os.system('sudo systemctl daemon-reload')
    # Enable and start the object-store service
    if bkp_type == 's3':
        os.system('sudo systemctl enable tvault-object-store')
        service_restart('tvault-object-store')
    # Enable and start the datamover service
    os.system('sudo systemctl enable tvault-contego')
    service_restart('tvault-contego')

    # Install was successful
    status_set('active', 'Ready...')
    # Add the flag "installed" since it's done
    set_flag('tvault-contego.installed')


@hook('stop')
def stop_handler():

    # Set the user defined "stopping" state when this hook event occurs.
    set_state('tvault-contego.stopping')


@when('tvault-contego.stopping')
def stop_tvault_contego_plugin():

    status_set('maintenance', 'Stopping...')

    # Call the script to stop and uninstll TrilioVault Datamover
    uninst_ret = uninstall_plugin()

    if uninst_ret:
        # Uninstall was successful
        # Remove the state "stopping" since it's done
        remove_state('tvault-contego.stopping')
