#!/usr/bin/env python3
"""
Prepare TrilioVault Ansible role for deployment by generating release-specific
task and handler files that contain only the kolla module appropriate for the
target OpenStack release.

Ansible fails to resolve a module name (e.g. kolla_docker) the moment it loads
a task/handler file that references it, even if a 'when' condition would prevent
the task from running. This script rewrites every affected file in place so that
only the relevant module is referenced, eliminating the parse error.

Files processed: any .yml in tasks/ or handlers/ that contains paired tasks named
with both (kolla_docker) and (kolla_container) suffixes. Release-specific files
(e.g. check-containers-kolla-docker.yml) are left untouched.

openstack_release is read automatically from /etc/kolla/globals.yml. Pass it as
an argument to override (useful when running the script outside the target host).

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


def has_paired_module_tasks(tasks):
    """Return True only if the file has both (kolla_docker) and (kolla_container) named tasks."""
    has_docker = any('(kolla_docker)' in t.get('name', '') for t in tasks if isinstance(t, dict))
    has_container = any('(kolla_container)' in t.get('name', '') for t in tasks if isinstance(t, dict))
    return has_docker and has_container


def handler_module_key(task):
    """Return the kolla module key used directly in this task, or None."""
    for key in task:
        if key in ('kolla_docker', 'kolla_container'):
            return key
    return None


def process_tasks(tasks, kolla_module):
    other_module = 'kolla_docker' if kolla_module == 'kolla_container' else 'kolla_container'
    result = []

    for task in tasks:
        if not isinstance(task, dict):
            result.append(task)
            continue

        name = task.get('name', '')

        # Name-suffix detection: "(kolla_docker)" or "(kolla_container)"
        has_target_suffix = f'({kolla_module})' in name
        has_other_suffix = f'({other_module})' in name

        if has_other_suffix:
            continue  # skip tasks explicitly for the other module

        if not has_target_suffix:
            # No suffix — check the module key the task actually uses
            used_module = handler_module_key(task)
            if used_module == other_module:
                continue  # skip tasks that directly call the other module

        # Keep this task; strip the triliovault_kolla_module when-condition
        t = dict(task)
        if 'when' in t:
            when = t['when']
            if isinstance(when, list):
                filtered = [w for w in when if 'triliovault_kolla_module' not in str(w)]
                if not filtered:
                    del t['when']
                elif len(filtered) == 1:
                    t['when'] = filtered[0]
                else:
                    t['when'] = filtered
            elif isinstance(when, str) and 'triliovault_kolla_module' in when:
                del t['when']

        result.append(t)

    return result


def process_file(filepath, kolla_module):
    """Process a single YAML file. Returns True if the file was modified."""
    with open(filepath) as f:
        tasks = yaml.safe_load(f)

    if not isinstance(tasks, list):
        return False

    if not has_paired_module_tasks(tasks):
        return False  # already release-specific or no module tasks — leave untouched

    processed = process_tasks(tasks, kolla_module)
    rel = os.path.relpath(filepath)
    print(f"  {rel}: {len(tasks)} tasks → {len(processed)} kept")

    header = (
        f"# Generated by prepare_triliovault_role.py for OpenStack release / kolla module: {kolla_module}\n"
        "---\n"
    )
    body = yaml.dump(processed, default_flow_style=False, allow_unicode=True, sort_keys=False)

    with open(filepath, 'w') as f:
        f.write(header)
        f.write(body)

    return True


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

    kolla_module = get_kolla_module(openstack_release)
    print(f"Kolla module      : {kolla_module}")
    print(f"Role path         : {role_path}")

    # Collect all yml files from tasks/ and handlers/
    target_dirs = [
        os.path.join(role_path, 'tasks'),
        os.path.join(role_path, 'handlers'),
    ]
    yml_files = []
    for d in target_dirs:
        if os.path.isdir(d):
            for fname in sorted(os.listdir(d)):
                if fname.endswith('.yml') or fname.endswith('.yaml'):
                    yml_files.append(os.path.join(d, fname))

    print(f"\nScanning {len(yml_files)} yml files...")
    modified = []
    for filepath in yml_files:
        if process_file(filepath, kolla_module):
            modified.append(filepath)

    if modified:
        print(f"\nUpdated {len(modified)} file(s).")
    else:
        print("\nNo files needed updating.")

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
