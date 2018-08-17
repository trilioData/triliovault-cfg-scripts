import os
import subprocess
import re
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
)


def validate_ip(ip):
    """Validate TVAULT_IPADDRESS provided by the user
    TVAULT_IPADDRESS should not be blank
    TVAULT_IPADDRESS should have a valid IP address and reachable
    """
    if ip.strip():
        # Not blank
        ip_addr = re.match(
            "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.)"
            "{3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$",
            ip)
        if ip_addr:
            # Valid IP address, check if it's reachable
            ip_re = os.system("ping -c 1 " + ip)
            return ip_re
        else:
            # Invalid IP address
            return 1
    else:
        # Blank
        return 1


@when_not('trilio-horizon-plugin.installed')
def install_trilio_horizon_plugin():

    status_set('maintenance', 'Installing...')

    # Push /usr/bin onto the start of $PATH from the hander for the specific
    # subprocess call for the install script.
    # This will make pip to be called from host install rather than virtualenv.
    s_env = os.environ.copy()
    s_env['PATH'] = '/usr/bin:{}'.format(s_env['PATH'])

    # Read config parameters TVault version, TVault IP, Horizon Path and
    # Webserver
    tv_version = config('TVAULT_VERSION')
    tv_ip = config('TVAULT_IPADDRESS')

    # Validate TVAULT_IPADDRESS
    validate_op = validate_ip(tv_ip)

    if validate_op:
        # IP address is invalid
        # Set status as blocked and return
        status_set(
            'blocked',
            'Invalid IP address, please provide correct IP address')
        return 1

    # Proceed as TVAULT IP Address is valid
    # Call install script to install the packages
    subprocess.check_call(
        ['files/trilio/install', tv_version, tv_ip], env=s_env)

    # Start the application
    status_set('maintenance', 'Starting...')

    # Call the script to re-start webserver
    subprocess.check_call(['files/trilio/webserver-restart'])

    status_set('active', 'Ready...')

    # Add the flag "installed" since it's done
    set_flag('trilio-horizon-plugin.installed')


@hook('stop')
def stop_handler():

    # Set the user defined "stopping" state when this hook event occurs.
    set_state('trilio-horizon-plugin.stopping')


@when('trilio-horizon-plugin.stopping')
def stop_trilio_horizon_plugin():

    status_set('maintenance', 'Stopping...')

    # Push /usr/bin onto the start of $PATH from the hander for the specific
    # subprocess call for the install script.
    # This will make pip to be called from host install rather than virtualenv.
    s_env = os.environ.copy()
    s_env['PATH'] = '/usr/bin:{}'.format(s_env['PATH'])

    # Call the script to stop and uninstll TVM Horizon Plugin
    subprocess.check_call(['files/trilio/stop'], env=s_env)

    # Remove the state "stopping" since it's done
    remove_state('trilio-horizon-plugin.stopping')
