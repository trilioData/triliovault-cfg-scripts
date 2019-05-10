from charms.reactive import when, set_flag
from charmhelpers.contrib import ansible
from charmhelpers.core.hookenv import (
    status_set,
    log,
)


@when('config.changed')
def install_configurator():
    log("Starting configuration...")
    status_set('maintenance', 'configuring tvault...')
    try:
        ansible.apply_playbook('site.yaml')
        status_set('active', 'Ready...')
    except Exception as e:
        log("ERROR:  {}".format(e))
        log("Check the ansible log in TVault to find more info")
        status_set('blocked', 'configuration failed')
    set_flag('trilio-configurator.installed')
