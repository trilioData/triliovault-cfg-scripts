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


@when_not('trilio-data-mover-api.installed')
def install_trilio_data_mover_api():

    status_set('maintenance', 'Installing...')

    # Read config parameters TVault IP
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
    subprocess.check_call(['files/trilio/install', tv_ip])

    # Start the application
    status_set('maintenance', 'Starting...')

    # Call the script to start Data Mover API
    subprocess.check_call(['files/trilio/start'])

    status_set('active', 'Ready...')

    # Add the flag "installed" since it's done
    set_flag('trilio-data-mover-api.installed')


@hook('stop')
def stop_handler():

    # Set the user defined "stopping" state when this hook event occurs.
    set_state('trilio-data-mover-api.stopping')


@when('trilio-data-mover-api.stopping')
def stop_trilio_data_mover_api():

    status_set('maintenance', 'Stopping...')

    # Call the script to stop and uninstll Data Mover
    subprocess.check_call(['files/trilio/stop'])

    # Remove the state "stopping" since it's done
    remove_state('trilio-data-mover-api.stopping')
