from charms.reactive import when, when_not, set_flag
from charmhelpers.contrib import ansible
from charmhelpers.core.hookenv import (
    status_set,
    log,
)

@when_not('trilio-configurator.installed')
def install_configurator():
    log("Starting configuration...")
    status_set('maintenance', 'configuring tvault...')
    try:
        ansible.apply_playbook('site.yaml')
        status_set('active', 'Ready...')
        set_flag('trilio-configurator.installed')
    except Exception as e:
        log("ERROR:  {}".format(e))
        log("Check the ansible log in TVault to find more info")
        status_set('blocked', 'configuration failed')
