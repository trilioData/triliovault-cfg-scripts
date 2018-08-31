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
from charmhelpers.contrib.python.packages import (
    pip_install,
)
from charmhelpers.core.host import (
    service_restart,
)
from subprocess import (
    check_output,
)


def validate_ip(ip):
    """Validate TrilioVault IP provided by the user
    TrilioVault IP should not be blank
    TrilioVault IP should have a valid IP address and reachable
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


def install_plugin(ip, ver):
    """Install Horizon plugin and workloadmgrclient packages
    from TVAULT_IPADDRESS provided by the user
    """

    pkg = "http://" + ip + \
          ":8081/packages/python-workloadmgrclient-" + ver + \
          ".tar.gz"

    try:
        pip_install(pkg, venv="/usr", options="--no-deps")
        log("TrilioVault WorkloadMgrClient package installation passed")
    except Exception as e:
        # workloadmgrclient package install failed
        log("TrilioVault WorkloadMgrClient package installation failed")
        log("With exception --{}".format(e))
        return False

    pkg = "http://" + ip + \
          ":8081/packages/tvault-horizon-plugin-" + ver + \
          ".tar.gz"

    try:
        pip_install(pkg, venv="/usr", options="--no-deps")
        log("TrilioVault Horizon Plugin package installation passed")
    except Exception as e:
        # Horixon Plugin package install failed
        log("TrilioVault Horizon Plugin package installation failed")
        log("With exception --{}".format(e))
        return False

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
    cmd = "/usr/bin/pip uninstall python-workloadmgrclient -y"
    wm_ret = os.system(cmd)

    if wm_ret:
        # workloadmgrclient package uninstall failed
        log("TrilioVault WorkloadMgrClient package un-installation failed")
        return False
    else:
        log("TrilioVault WorkloadMgrClient package uninstalled successfully")

    cmd = "/usr/bin/pip uninstall tvault-horizon-plugin -y"
    hp_ret = os.system(cmd)

    if hp_ret:
        # Horizon Plugin package uninstall failed
        log("TrilioVault Horizon Plugin package un-installation failed")
        return False
    else:
        log("TrilioVault Horizon Plugin package uninstalled successfully")

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
    if install_plugin(tv_ip, tv_version):
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
