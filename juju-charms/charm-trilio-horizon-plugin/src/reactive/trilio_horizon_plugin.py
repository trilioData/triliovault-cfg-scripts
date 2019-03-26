import os
import re
import netaddr
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
    application_version_set,
)
from charmhelpers.core.host import (
    service_restart,
)
from subprocess import (
    check_output,
)
from charmhelpers.fetch import (
    add_source,
    apt_install,
    apt_update,
    apt_purge,
)


def validate_ip(ip):
    """Validate TrilioVault IP provided by the user
    TrilioVault IP should not be blank
    TrilioVault IP should have a valid IP address and reachable
    """
    if ip and ip.strip():
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


def copy_template():
    """
    Copy TrilioVault Horizon HTML Template from files/trilio dir
    """
    dashboard_path = '/usr/local/lib/python2.7/dist-packages/dashboards/'

    # install and compress new dashboard if it's provided by user
    if os.path.isfile("files/trilio/trilio-horizon-plugin.html"):
        old = (
            '{}/workloads_admin/templates/workloads_admin/index.html'.format(
                dashboard_path))
        new = (
            '{}/workloads_admin/templates/workloads_admin/orig.html'.format(
                dashboard_path))
        os.system('cp ' + old + ' ' + new)
        os.system(
            'cp files/trilio/trilio-horizon-plugin.html {}/workloads_admin'
            '/templates/workloads_admin/index.html'.format(dashboard_path))
        os.system(
            'cd /usr/share/openstack-dashboard;'
            '/usr/bin/python manage.py collectstatic;'
            'python manage.py compress --force')


def copy_files():
    """
    Copy TrilioVault Horizon panel files from files/trilio dir
    """
    horizon_path = '/usr/share/openstack-dashboard/'
    os.system(
        'cp files/trilio/tvault_panel_group.py {}/openstack_dashboard'
        '/local/enabled/tvault_panel_group.py'.format(horizon_path))
    os.system(
        'cp files/trilio/tvault_admin_panel_group.py {}/openstack_dashboard'
        '/local/enabled/tvault_admin_panel_group.py'.format(horizon_path))
    os.system(
        'cp files/trilio/tvault_panel.py {}/openstack_dashboard'
        '/local/enabled/tvault_panel.py'.format(horizon_path))
    os.system(
        'cp files/trilio/tvault_settings_panel.py {}/openstack_dashboard'
        '/local/enabled/tvault_settings_panel.py'.format(horizon_path))
    os.system(
        'cp files/trilio/tvault_admin_panel.py {}/openstack_dashboard'
        '/local/enabled/tvault_admin_panel.py'.format(horizon_path))
    os.system(
        'cp files/trilio/tvault_filter.py {}/openstack_dashboard'
        '/templatetags/tvault_filter.py'.format(horizon_path))

    # Restart webserver apache2
    service_restart("apache2")

    # write content into destination file - sync_static.py
    os.system('cp files/trilio/sync_static.py /tmp/sync_static.py')

    # Change the working directory to horizon and excute shell command
    os.system(
        '{}/manage.py shell < /tmp/sync_static.py &> '
        '/dev/null'.format(horizon_path))

    # Remove temporary file
    os.system('rm /tmp/sync_static.py')

    # Copy Dashboard HTML template if exists
    copy_template()


def delete_files():
    """
    Delete TrilioVault Horizon panel files
    """
    horizon_path = '/usr/share/openstack-dashboard/'
    os.system(
        'rm {}/openstack_dashboard/local/enabled/'
        'tvault_panel_group.py*'.format(horizon_path))
    os.system(
        'rm {}/openstack_dashboard/local/enabled/'
        'tvault_admin_panel_group.py*'.format(horizon_path))
    os.system(
        'rm {}/openstack_dashboard/local/enabled/'
        'tvault_panel.py*'.format(horizon_path))
    os.system(
        'rm {}/openstack_dashboard/local/enabled/'
        'tvault_settings_panel.py*'.format(horizon_path))
    os.system(
        'rm {}/openstack_dashboard/local/enabled/'
        'tvault_admin_panel.py*'.format(horizon_path))
    os.system(
        'rm {}/openstack_dashboard/templatetags/'
        'tvault_filter.py*'.format(horizon_path))

    # write content into destination file - sync_static1.py
    os.system('cp files/trilio/sync_static1.py /tmp/sync_static1.py')

    # Change the working directory to horizon and excute shell command
    os.system(
        '{}/manage.py shell < /tmp/sync_static1.py &> '
        '/dev/null'.format(horizon_path))

    # Remove temporary file
    os.system('rm /tmp/sync_static1.py')


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


def install_plugin(ip, ver, venv):
    """Install Horizon plugin and workloadmgrclient packages
    from TVAULT_IPADDRESS provided by the user
    """

    add_source('deb http://{}:8085 deb-repo/'.format(ip))

    try:
        apt_update()
        apt_install(['python-workloadmgrclient'],
                    options=['--allow-unauthenticated'], fatal=True)
        log("TrilioVault WorkloadMgrClient package installation passed")
    except Exception as e:
        # workloadmgrclient package install failed
        log("TrilioVault WorkloadMgrClient package installation failed")
        log("With exception --{}".format(e))
        return False

    try:
        apt_install(['tvault-horizon-plugin'],
                    options=['--allow-unauthenticated'], fatal=True)
        log("TrilioVault Horizon Plugin package installation passed")
    except Exception as e:
        # Horixon Plugin package install failed
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

    try:
        # Uninstall python-workloadmgrclient
        apt_purge(['python-workloadmgrclient']),
        log("TrilioVault WorkloadMgrClient package uninstalled successfully")
    except Exception as e:
        # package uninstallation failed
        log("TrilioVault WorkloadMgrClient package un-installation failed:"
            " {}".format(e))
        return False

    try:
        # Uninstall TrilioVautl Horizon Plugin package
        apt_purge(['tvault-horizon-plugin']),
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

    # Read config parameters TrilioVault IP
    tv_ip = config('triliovault-ip')

    # Validate TrilioVault IP
    if not validate_ip(tv_ip):
        # IP address is invalid
        # Set status as blocked and return
        status_set(
            'blocked',
            'Invalid IP address, please provide correct IP address')
        application_version_set('Unknown')
        return

    # Proceed as TrilioVault IP Address is valid
    # Get latest version of the tvault-horizon-plugin pkg
    tv_version = get_new_version('tvault-horizon-plugin')

    # Call install handler to install the packages
    if install_plugin(tv_ip, tv_version, '/usr'):
        # Install was successful
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
