import os
import re
from charms.reactive import (
    when,
    when_not,
    set_flag,
    clear_flag,
    hook,
    remove_state,
    set_state,
)
from charmhelpers.core.hookenv import (
    status_set,
    config,
    log,
    application_version_set,
)
from charmhelpers.core.host import (
    service_restart,
)
from subprocess import (
    check_output,
)
from charmhelpers.fetch import (
    apt_install,
    apt_update,
    apt_purge,
)


def copy_files():
    horizon_path = config("horizon-path")

    # Restart webserver apache2
    service_restart("apache2")

    # write content into destination file - sync_static.py
    os.system('cp files/trilio/sync_static.py /tmp/sync_static.py')

    # Change the working directory to horizon and excute shell command
    os.system(
        '/usr/bin/python{0} {1}/manage.py shell < /tmp/sync_static.py &> '
        '/dev/null'.format(config('python-version'), horizon_path))

    # Remove temporary file
    os.system('rm /tmp/sync_static.py')

    os.system(
            '/usr/bin/python{0} {1}/manage.py collectstatic;'
            '/usr/bin/python{0} {1}/manage.py compress --force'.format(
             config('python-version'), horizon_path))


def delete_files():
    horizon_path = config("horizon-path")

    # write content into destination file - sync_static1.py
    os.system('cp files/trilio/sync_static1.py /tmp/sync_static1.py')

    # Change the working directory to horizon and excute shell command
    os.system(
        '/usr/bin/python{0} {1}/manage.py shell < /tmp/sync_static1.py &> '
        '/dev/null'.format(config('python-version'), horizon_path))

    # Remove temporary file
    os.system('rm /tmp/sync_static1.py')


def get_new_version(pkg):
    """
    Get the latest version available on the TrilioVault node.
    """
    apt_cmd = "apt list tvault-horizon-plugin"
    pkg = check_output(apt_cmd.split()).decode('utf-8')
    new_ver = re.search(r'\s([\d.]+)', pkg).group().strip()

    return new_ver


def install_plugin(pkg_source):
    """Install Horizon plugin and workloadmgrclient packages
    from TVAULT_IPADDRESS provided by the user
    """
    # add triliovault package repo
    os.system('sudo echo "{}" > '
              '/etc/apt/sources.list.d/trilio-gemfury-sources.list'.format(
               config('triliovault-pkg-source')))
    if config('python-version') == 3:
        wlm_pkgs_name = 'python3-workloadmgrclient'
        plugin_pkg_name = 'python3-tvault-horizon-plugin'
    else:
        wlm_pkgs_name = 'python-workloadmgrclient'
        plugin_pkg_name = 'tvault-horizon-plugin'

    try:
        apt_update()
        apt_install([wlm_pkgs_name],
                    options=['--allow-unauthenticated'], fatal=True)
        log("TrilioVault WorkloadMgrClient package installation passed")
    except Exception as e:
        # workloadmgrclient package install failed
        log("TrilioVault WorkloadMgrClient package installation failed")
        log("With exception --{}".format(e))
        return False

    try:
        apt_install([plugin_pkg_name],
                    options=['--allow-unauthenticated'], fatal=True)
        log("TrilioVault Horizon Plugin package installation passed")
    except Exception as e:
        # Horizon Plugin package install failed
        log("TrilioVault Horizon Plugin package installation failed")
        log("With exception --{}".format(e))
        return False

    # Copy TrilioVault files
    copy_files()

    # Start the application
    status_set('maintenance', 'Starting...')

    try:
        service_restart("apache2")
    except Exception as e:
        # apache2 restart failed
        log("Apache2 restart failed with exception --{}".format(e))
        return False

    return True


def uninstall_plugin():
    # pip_uninstall doesn't work as it calls pip from venv of charm
    # Can not pass venv to pip_uninstall like pip_install
    # Using alternate approach for now
    # Uninstall Horizon plugin and workloadmgrclient packages
    # Start with deleting TrilioVault files
    delete_files()
    if config('python-version') == 3:
        wlm_pkgs_name = 'python3-workloadmgrclient'
        plugin_pkg_name = 'python3-tvault-horizon-plugin'
    else:
        wlm_pkgs_name = 'python-workloadmgrclient'
        plugin_pkg_name = 'tvault-horizon-plugin'

    try:
        # Uninstall python-workloadmgrclient
        apt_purge([wlm_pkgs_name]),
        log("TrilioVault WorkloadMgrClient package uninstalled successfully")
    except Exception as e:
        # package uninstallation failed
        log("TrilioVault WorkloadMgrClient package un-installation failed:"
            " {}".format(e))
        return False

    try:
        # Uninstall TrilioVautl Horizon Plugin package
        apt_purge([plugin_pkg_name]),
        log("TrilioVault Horizon Plugin package uninstalled successfully")
    except Exception as e:
        # package uninstallation failed
        log("TrilioVault Horizon Plugin package un-installation failed:"
            " {}".format(e))
        return False

    # Re-start the Webserver
    try:
        service_restart("apache2")
    except Exception as e:
        # apache2 restart failed
        log("Apache2 restart failed with exception --{}".format(e))
        return False

    return True


@when_not('trilio-horizon-plugin.installed')
def install_trilio_horizon_plugin():

    status_set('maintenance', 'Installing...')

    # Push /usr/bin onto the start of $PATH from the hander for the specific
    # subprocess call for the install script.
    # This will make pip to be called from host install rather than virtualenv.

    # Read config parameters triliovault package repository
    tv_pkg_source = config('triliovault-pkg-source')

    # Call install handler to install the packages
    if install_plugin(tv_pkg_source):
        # Install was successful
        # Get latest version of the tvault-horizon-plugin pkg
        tv_version = get_new_version('tvault-horizon-plugin')
        status_set('active', 'Ready...')
        application_version_set(tv_version)

        # Add the flag "installed" since it's done
        set_flag('trilio-horizon-plugin.installed')
    else:
        # Install failed
        status_set('blocked', 'Packages installation failed.....retry..')


@hook('stop')
def stop_handler():

    # Set the user defined "stopping" state when this hook event occurs.
    set_state('trilio-horizon-plugin.stopping')


@when('trilio-horizon-plugin.stopping')
def stop_trilio_horizon_plugin():

    status_set('maintenance', 'Stopping...')

    # Call the script to stop and uninstll TrilioVault Horizon Plugin
    uninst_ret = uninstall_plugin()

    if uninst_ret:
        # Uninstall was successful
        # Remove the state "stopping" since it's done
        remove_state('trilio-horizon-plugin.stopping')


@hook('upgrade-charm')
def upgrade_charm():
    # Delete static files
    delete_files()
    # Clear the flag
    clear_flag('trilio-horizon-plugin.installed')
