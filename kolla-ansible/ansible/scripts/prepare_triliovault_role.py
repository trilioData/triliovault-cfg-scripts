#!/usr/bin/env python3
"""
Prepare TrilioVault Ansible role for deployment by generating a release-specific
handlers/main.yml that contains only the kolla module appropriate for the target
OpenStack release.

Ansible fails at parse time if a handler references a module (e.g. kolla_docker)
that is not installed, even when a 'when' condition would prevent it from running.
This script rewrites handlers/main.yml in place so that only the relevant module
is referenced, eliminating the parse error.

openstack_release is read automatically from /etc/kolla/globals.yml. Pass it as
an argument to override (useful when running outside the target host).

Usage:
    python3 prepare_triliovault_role.py [openstack_release] [role_path]

Arguments:
    openstack_release  OpenStack release name (e.g. zed, 2023.1, 2024.1, 2025.1)
                       If omitted, read from /etc/kolla/globals.yml
    role_path          Path to the triliovault role directory
                       (default: <script_dir>/../roles/triliovault)

Examples:
    python3 prepare_triliovault_role.py
    python3 prepare_triliovault_role.py 2025.1
    python3 prepare_triliovault_role.py zed /tmp/roles/triliovault

After running, copy the role to kolla-ansible:
    # Modern releases (Bobcat / 2023.2 and later) — kolla-ansible in venv:
    export venv_path=/opt/kolla-venv
    rm -rf $venv_path/share/kolla-ansible/ansible/roles/triliovault
    cp -R <role_path> $venv_path/share/kolla-ansible/ansible/roles/

    # Older releases (Zed / Antelope) — system-wide install:
    rm -rf /usr/local/share/kolla-ansible/ansible/roles/triliovault
    cp -R <role_path> /usr/local/share/kolla-ansible/ansible/roles/
"""

import sys
import os

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install it with: pip install pyyaml")
    sys.exit(1)

# Releases that ship kolla_docker instead of kolla_container
KOLLA_DOCKER_RELEASES = {'zed', '2023.1'}

# Candidate paths for the kolla globals file (tried in order)
KOLLA_GLOBALS_PATHS = [
    '/etc/kolla/globals.yml',
    '/etc/kolla/globals.yaml',
]


def read_openstack_release_from_globals():
    """Read openstack_release from /etc/kolla/globals.yml."""
    for path in KOLLA_GLOBALS_PATHS:
        if not os.path.exists(path):
            continue
        with open(path) as f:
            data = yaml.safe_load(f)
        if isinstance(data, dict) and 'openstack_release' in data:
            return data['openstack_release'], path
        print(f"Warning: {path} exists but does not contain 'openstack_release'")
    return None, None


def get_kolla_module(openstack_release):
    return 'kolla_docker' if openstack_release.lower() in KOLLA_DOCKER_RELEASES else 'kolla_container'


def handler_module_key(handler):
    """Return the kolla module key used directly in this handler task, or None."""
    for key in handler:
        if key in ('kolla_docker', 'kolla_container'):
            return key
    return None


def process_handlers(handlers, kolla_module):
    other_module = 'kolla_docker' if kolla_module == 'kolla_container' else 'kolla_container'
    result = []

    for handler in handlers:
        name = handler.get('name', '')

        # Name-suffix detection: "(kolla_docker)" or "(kolla_container)"
        has_target_suffix = f'({kolla_module})' in name
        has_other_suffix = f'({other_module})' in name

        if has_other_suffix:
            continue  # skip handlers explicitly for the other module

        if not has_target_suffix:
            # No suffix — check the module key the handler actually uses
            used_module = handler_module_key(handler)
            if used_module == other_module:
                continue  # skip handlers that directly call the other module

        # Keep this handler; strip the triliovault_kolla_module when-condition
        h = dict(handler)
        if 'when' in h:
            when = h['when']
            if isinstance(when, list):
                filtered = [w for w in when if 'triliovault_kolla_module' not in str(w)]
                if not filtered:
                    del h['when']
                elif len(filtered) == 1:
                    h['when'] = filtered[0]
                else:
                    h['when'] = filtered
            elif isinstance(when, str) and 'triliovault_kolla_module' in when:
                del h['when']

        result.append(h)

    return result


def main():
    args = [a for a in sys.argv[1:] if a not in ('-h', '--help')]
    if '-h' in sys.argv or '--help' in sys.argv:
        print(__doc__)
        sys.exit(0)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_role = os.path.normpath(os.path.join(script_dir, '..', 'roles', 'triliovault'))

    # Determine openstack_release: argument takes priority, then globals file
    if args:
        openstack_release = args[0]
        role_path = os.path.normpath(args[1]) if len(args) > 1 else default_role
        print(f"OpenStack release : {openstack_release} (from argument)")
    else:
        openstack_release, globals_path = read_openstack_release_from_globals()
        if not openstack_release:
            print("Error: openstack_release not found in /etc/kolla/globals.yml")
            print("Pass it as an argument: python3 prepare_triliovault_role.py <release>")
            sys.exit(1)
        role_path = default_role
        print(f"OpenStack release : {openstack_release} (from {globals_path})")

    handlers_file = os.path.join(role_path, 'handlers', 'main.yml')
    if not os.path.exists(handlers_file):
        print(f"Error: handlers file not found: {handlers_file}")
        sys.exit(1)

    kolla_module = get_kolla_module(openstack_release)
    print(f"Kolla module      : {kolla_module}")
    print(f"Role path         : {role_path}")

    with open(handlers_file) as f:
        handlers = yaml.safe_load(f)

    if not isinstance(handlers, list):
        print("Error: handlers/main.yml did not parse as a YAML list")
        sys.exit(1)

    processed = process_handlers(handlers, kolla_module)
    print(f"Handlers          : {len(handlers)} total → {len(processed)} kept for {kolla_module}")

    header = (
        f"# Generated by prepare_triliovault_role.py for OpenStack {openstack_release}\n"
        f"# Kolla module: {kolla_module}\n"
        f"# Source handlers: {len(handlers)}, kept: {len(processed)}\n"
        "---\n"
    )
    body = yaml.dump(processed, default_flow_style=False, allow_unicode=True, sort_keys=False)

    with open(handlers_file, 'w') as f:
        f.write(header)
        f.write(body)

    print(f"\nUpdated  : {handlers_file}")

    print("\nNext — copy the role to kolla-ansible:")
    if kolla_module == 'kolla_container':
        print("  export venv_path=/opt/kolla-venv")
        print("  rm -rf $venv_path/share/kolla-ansible/ansible/roles/triliovault")
        print(f"  cp -R {role_path} $venv_path/share/kolla-ansible/ansible/roles/")
    else:
        print("  rm -rf /usr/local/share/kolla-ansible/ansible/roles/triliovault")
        print(f"  cp -R {role_path} /usr/local/share/kolla-ansible/ansible/roles/")


if __name__ == '__main__':
    main()
