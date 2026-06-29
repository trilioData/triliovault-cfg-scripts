#!/usr/bin/env python3
"""
prepare_install_upgrade.py — Automate T4O setup on Kolla-Ansible OpenStack.

Performs all pre-deployment configuration steps for both install and
upgrade scenarios:

  1. Prepare and copy the triliovault Ansible role
  2. Merge Trilio globals into /etc/kolla/globals.yml
  3. Add Trilio passwords to /etc/kolla/passwords.yml
  4. Update the Trilio plays in the kolla site.yml
  5. Replace Trilio inventory groups in the kolla inventory file
  6. Patch nova-cell volumes for snapshot mount support
  7. Create Horizon custom settings directory and file

Install vs upgrade behaviour differences:
  globals.yml  — install: append Trilio block; upgrade: replace block keeping
                 customer-set values for empty-default parameters (credentials
                 etc.), update Trilio-owned values (tags, fixed defaults).
  passwords.yml — both modes: generate only the keys that are missing;
                  never regenerates keys that already exist.
  site.yml     — both modes: replace the full Trilio block with fresh content
                 (no customer customisation in site.yml).
  inventory    — both modes: fully replace the Trilio block.

Usage:
    python3 prepare_install_upgrade.py --os-release <release> --mode <install|upgrade>
                                       [--venv-path <path>]
                                       [--inventory-file <path>]
                                       [--globals-file <path>]

Arguments:
    --os-release       OpenStack release name (e.g. 2025.1, 2024.2, 2023.1, zed)
    --mode             'install' for new install, 'upgrade' for existing deployment
    --venv-path        Path to kolla-ansible venv (default: /opt/kolla-venv)
    --inventory-file   Path to kolla inventory file (default: /root/multinode)
    --globals-file     Path to kolla globals.yml  (default: /etc/kolla/globals.yml)

Examples:
    python3 prepare_install_upgrade.py --os-release 2025.1 --mode install
    python3 prepare_install_upgrade.py --os-release 2025.1 --mode upgrade
    python3 prepare_install_upgrade.py --os-release 2024.2 --mode upgrade \\
        --venv-path /opt/kolla-venv --inventory-file /root/multinode
"""

import argparse
import os
import re
import shutil
import string
import subprocess
import sys
from datetime import datetime

LOG_FILE = 'prepare_install_upgrade.log'


class _Tee:
    """Write to both a file and the original stream simultaneously."""
    def __init__(self, stream, log_fh):
        self._stream = stream
        self._log = log_fh

    def write(self, data):
        self._stream.write(data)
        self._log.write(data)

    def flush(self):
        self._stream.flush()
        self._log.flush()

    def __getattr__(self, name):
        return getattr(self._stream, name)

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install: pip install pyyaml")
    sys.exit(1)

# ─── Constants ────────────────────────────────────────────────────────────────

MARKER_BEGIN = "# BEGIN TRILIOVAULT MANAGED BLOCK - DO NOT EDIT THIS LINE"
MARKER_END = "# END TRILIOVAULT MANAGED BLOCK - DO NOT EDIT THIS LINE"

TRILIO_PASSWORD_KEYS = [
    'triliovault_wlm_keystone_password',
    'triliovault_wlm_database_password',
    'triliovault_wlm_rabbitmq_password',
    'triliovault_datamover_keystone_password',
    'triliovault_datamover_database_password',
]

# nova-cell list variables that need the /var/trilio mount appended
NOVA_CELL_VOLUME_KEYS = [
    'nova_libvirt_default_volumes',
    'nova_compute_default_volumes',
]

TRILIO_VOLUME_ENTRY = '"/var/trilio:/var/trilio:shared"'

# site.yml play names owned by Trilio — used to strip orphaned plays
TRILIO_PLAY_NAMES = [
    'Apply haproxy config for triliovault services',
    'Apply role triliovault',
]

HORIZON_SETTINGS_CONTENT = (
    'from openstack_dashboard.settings import HORIZON_CONFIG\n'
    'HORIZON_CONFIG["customization_module"] = "trilio_dashboard.overrides"\n'
)

SUPPORTED_RELEASES = [
    'zed', '2023.1', '2023.2', '2024.1', '2024.2', '2025.1', '2025.2',
]

PASSWORD_LENGTH = 42

# ─── Utilities ────────────────────────────────────────────────────────────────

def die(msg):
    print(f"\nERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def backup_file(filepath, backup_dir):
    """Copy filepath into backup_dir before modification. Handles basename collisions."""
    os.makedirs(backup_dir, exist_ok=True)
    basename = os.path.basename(filepath)
    dest = os.path.join(backup_dir, basename)
    if os.path.exists(dest):
        base, ext = os.path.splitext(basename)
        counter = 1
        while os.path.exists(dest):
            dest = os.path.join(backup_dir, f"{base}_{counter}{ext}")
            counter += 1
    shutil.copy2(filepath, dest)
    print(f"    backup → {dest}")
    return dest


def read_file(filepath):
    with open(filepath, encoding='utf-8') as f:
        return f.read()


def write_file(filepath, content):
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)


def generate_password(length=PASSWORD_LENGTH):
    """Generate a random alphanumeric password using os.urandom."""
    alphabet = string.ascii_letters + string.digits
    raw = os.urandom(length * 2)
    return ''.join(alphabet[b % len(alphabet)] for b in raw)[:length]


# ─── Marker-block helpers ─────────────────────────────────────────────────────

def _make_block(content):
    return f"{MARKER_BEGIN}\n{content.strip()}\n{MARKER_END}\n"


def has_marker_block(text):
    return MARKER_BEGIN in text and MARKER_END in text


def _strip_trilio_plays(text):
    """
    Remove Trilio-owned plays from site.yml content, identified by their
    - name: fields. Used to clean up plays added outside the marker block
    (e.g. from a manual setup before this script existed).
    """
    segments = re.split(r'(?=^- name:)', text, flags=re.MULTILINE)
    filtered = []
    for seg in segments:
        if any(f'- name: {name}' in seg for name in TRILIO_PLAY_NAMES):
            # Remove this play and strip trailing blank lines from the previous segment
            if filtered:
                filtered[-1] = filtered[-1].rstrip('\n') + '\n'
        else:
            filtered.append(seg)
    return ''.join(filtered)


def extract_block_content(text):
    """Return the text between the Trilio marker lines, or None if absent."""
    begin = text.find(MARKER_BEGIN)
    end = text.find(MARKER_END)
    if begin == -1 or end == -1:
        return None
    start = begin + len(MARKER_BEGIN)
    return text[start:end].strip('\n')


def insert_or_replace_block(filepath, new_content):
    """
    Insert the Trilio managed block into filepath if absent, or replace it.
    Returns 'appended' or 'replaced'.
    """
    current = read_file(filepath)
    block = _make_block(new_content)

    if has_marker_block(current):
        pattern = re.escape(MARKER_BEGIN) + r'.*?' + re.escape(MARKER_END) + r'\n?'
        updated = re.sub(pattern, block, current, flags=re.DOTALL)
        write_file(filepath, updated)
        return 'replaced'
    else:
        updated = current.rstrip('\n') + '\n\n' + block
        write_file(filepath, updated)
        return 'appended'


# ─── Globals merge ────────────────────────────────────────────────────────────

def _parse_kv_raw(text):
    """
    Extract { key: raw_value } from YAML text, skipping comments and blank lines.
    raw_value is the verbatim string after the colon (may include quotes).
    Keys with no value (bare `key:`) are stored as empty string.
    """
    result = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$', stripped)
        if m:
            result[m.group(1)] = m.group(2).strip()
    return result


def _is_empty_yaml_value(raw):
    """Return True if the raw YAML value represents an absent / empty string."""
    return raw in ('', '""', "''")


def merge_globals_content(template_text, old_values):
    """
    Produce merged globals text.

    Rules applied per key in the new template:
    - Template value is empty (``""`` or blank):
        customer previously set a value  → preserve the customer value
        customer had no value            → keep the empty template slot
    - Template value is non-empty Trilio default (tags, fixed settings):
        always use the new template value so version bumps take effect
    - Key is new (not in old block)     → use template value, log as NEW
    - Key removed from template         → silently dropped (not in new template)

    Comments and blank lines are preserved from the new template.
    Returns (merged_text, new_keys_list).
    """
    lines = template_text.splitlines(keepends=True)
    result = []
    new_keys = []

    for line in lines:
        stripped = line.strip()

        if not stripped or stripped.startswith('#'):
            result.append(line)
            continue

        m = re.match(r'^(\s*)([a-zA-Z_][a-zA-Z0-9_]*)(\s*:\s*)(.*)$', line.rstrip('\n'))
        if not m:
            result.append(line)
            continue

        indent, key, sep, template_val = m.groups()
        template_val_stripped = template_val.strip()

        if key not in old_values:
            new_keys.append(key)
            result.append(line)
        elif _is_empty_yaml_value(template_val_stripped) and old_values[key]:
            # Empty slot in template — use what the customer previously set
            result.append(f"{indent}{key}{sep}{old_values[key]}\n")
        else:
            # Non-empty Trilio default — use the new template value
            result.append(line)

    return ''.join(result), new_keys


def step_globals(globals_file, trilio_globals_file, mode, backup_dir):
    print("\n[2] globals.yml")

    if not os.path.exists(trilio_globals_file):
        die(f"Trilio globals file not found: {trilio_globals_file}")

    template_text = read_file(trilio_globals_file)
    current_globals = read_file(globals_file)

    old_values = {}
    has_existing_block = has_marker_block(current_globals)

    if mode == 'upgrade':
        if has_existing_block:
            block_content = extract_block_content(current_globals)
            if block_content:
                old_values = _parse_kv_raw(block_content)
                print(f"  Found existing Trilio block with {len(old_values)} parameter(s)")
        else:
            # No marker block — system was set up manually; scan full file for existing values
            old_values = _parse_kv_raw(current_globals)
            print(f"  No existing marker block — reading existing values from globals.yml")

    merged_text, new_keys = merge_globals_content(template_text, old_values)

    backup_file(globals_file, backup_dir)
    action = insert_or_replace_block(globals_file, merged_text)
    print(f"  {action} Trilio globals block in {globals_file}")

    # Only report keys with empty defaults — these are the ones the user must fill in
    template_kv = _parse_kv_raw(template_text)
    actionable_new = [k for k in new_keys if _is_empty_yaml_value(template_kv.get(k, ''))]
    if actionable_new:
        print("  NEW parameters (empty — fill in before deploying):")
        for k in actionable_new:
            print(f"    + {k}")

    if old_values:
        template_keys = set(template_kv.keys())
        removed = [k for k in old_values if k not in template_keys]
        if removed:
            print("  Parameters removed (no longer in this release):")
            for k in removed:
                print(f"    - {k}")


# ─── Passwords ────────────────────────────────────────────────────────────────

_TRILIO_PWD_COMMENT = '# Trilio passwords — added by prepare_install_upgrade.py\n'


def _split_passwords_file(content):
    """
    Split passwords.yml into (kolla_section, trilio_section).
    kolla_section: everything before our comment marker, trailing whitespace stripped.
    trilio_section: our comment + Trilio key lines (empty string if not yet present).
    """
    idx = content.find(_TRILIO_PWD_COMMENT)
    if idx >= 0:
        return content[:idx].rstrip(), content[idx:]
    return content.rstrip(), ''


def step_passwords(passwords_file, mode, backup_dir):
    print("\n[3] passwords.yml")

    if not os.path.exists(passwords_file):
        die(f"Kolla passwords file not found: {passwords_file}")

    current = read_file(passwords_file)
    existing = yaml.safe_load(current) or {}
    missing = [k for k in TRILIO_PASSWORD_KEYS if k not in existing]

    kolla_part, trilio_part = _split_passwords_file(current)
    # Normalized = kolla (no trailing blank lines) + blank line + Trilio section
    normalized = kolla_part + '\n\n' + trilio_part if trilio_part else None

    if not missing:
        # Normalize trailing blank lines even when skipping password generation
        if normalized and normalized != current:
            backup_file(passwords_file, backup_dir)
            write_file(passwords_file, normalized)
            print("  All Trilio password keys already present — normalized blank lines")
        else:
            print("  All Trilio password keys already present — skipping")
        return

    if mode == 'upgrade':
        print(f"  {len(missing)} missing password key(s) — adding only missing ones")
    else:
        print(f"  Generating {len(missing)} password(s)")

    new_passwords = {k: generate_password() for k in missing}

    backup_file(passwords_file, backup_dir)
    with open(passwords_file, 'w', encoding='utf-8') as f:
        f.write(kolla_part + '\n')
        f.write('\n' + _TRILIO_PWD_COMMENT)
        if trilio_part:
            # Preserve existing Trilio passwords (lines after the comment)
            f.write(trilio_part[len(_TRILIO_PWD_COMMENT):].lstrip('\n'))
        for key, val in new_passwords.items():
            f.write(f'{key}: {val}\n')

    print(f"  Added {len(missing)} password key(s) to {passwords_file}")


# ─── Site.yml ─────────────────────────────────────────────────────────────────

def step_site(site_file, trilio_site_file, backup_dir):
    print("\n[4] site.yml")

    if not os.path.exists(trilio_site_file):
        die(f"Trilio site file not found: {trilio_site_file}")

    new_site_content = read_file(trilio_site_file)
    current = read_file(site_file)

    # Remove existing marker block (handles re-runs via this script)
    if has_marker_block(current):
        block_pattern = re.escape(MARKER_BEGIN) + r'.*?' + re.escape(MARKER_END) + r'\n?'
        current = re.sub(block_pattern, '', current, flags=re.DOTALL)

    # Remove any Trilio plays sitting outside the marker block
    # (handles manual setups and mixed states like the one above)
    current = _strip_trilio_plays(current)

    backup_file(site_file, backup_dir)
    updated = current.rstrip('\n') + '\n\n' + _make_block(new_site_content)
    write_file(site_file, updated)
    print(f"  replaced Trilio plays block in {site_file}")


# ─── Inventory ────────────────────────────────────────────────────────────────

def step_inventory(inventory_file, trilio_inventory_file, backup_dir):
    print("\n[5] Inventory")

    if not os.path.exists(inventory_file):
        die(f"Inventory file not found: {inventory_file}")

    inv_content = read_file(trilio_inventory_file)

    backup_file(inventory_file, backup_dir)
    action = insert_or_replace_block(inventory_file, inv_content)
    print(f"  {action} Trilio inventory block in {inventory_file}")


# ─── Ansible role ─────────────────────────────────────────────────────────────

def step_role(script_dir, os_release, venv_path):
    print("\n[1] Ansible role")

    prepare_script = os.path.join(script_dir, 'prepare_triliovault_role.py')
    role_src = os.path.normpath(os.path.join(script_dir, '..', 'roles', 'triliovault'))
    role_dst = os.path.join(
        venv_path, 'share', 'kolla-ansible', 'ansible', 'roles', 'triliovault'
    )

    print(f"  Running prepare_triliovault_role.py for release {os_release}")
    subprocess.run([sys.executable, prepare_script, os_release], check=True)

    if os.path.exists(role_dst):
        shutil.rmtree(role_dst)
    shutil.copytree(role_src, role_dst)
    print(f"  Role copied to {role_dst}")


# ─── Nova-cell volumes ────────────────────────────────────────────────────────

def step_nova_cell_volumes(venv_path, backup_dir):
    """Append /var/trilio mount to nova_libvirt and nova_compute volume lists."""
    print("\n[6] Nova-cell volumes")

    nova_defaults = os.path.join(
        venv_path, 'share', 'kolla-ansible', 'ansible',
        'roles', 'nova-cell', 'defaults', 'main.yml',
    )

    if not os.path.exists(nova_defaults):
        print(f"  Warning: {nova_defaults} not found — skipping")
        return

    content = read_file(nova_defaults)

    if '/var/trilio:/var/trilio:shared' in content:
        print("  Already patched")
        return

    patched = []

    for key in NOVA_CELL_VOLUME_KEYS:
        # Match the variable declaration followed by its YAML list items.
        # List items start with one or more spaces then a dash.
        pattern = rf'(^{re.escape(key)}\s*:(?:\n[ \t]+-[^\n]*)+)'
        match = re.search(pattern, content, re.MULTILINE)
        if not match:
            print(f"  Warning: {key} list not found in nova-cell defaults — skipping")
            continue

        block = match.group(1)
        # Determine indentation from existing list items
        items = re.findall(r'^([ \t]+)-', block, re.MULTILINE)
        indent = items[-1] if items else '  '
        new_block = block.rstrip('\n') + f'\n{indent}- {TRILIO_VOLUME_ENTRY}'
        content = content.replace(block, new_block, 1)
        patched.append(key)

    if patched:
        backup_file(nova_defaults, backup_dir)
        write_file(nova_defaults, content)
        print(f"  Patched: {', '.join(patched)}")
    else:
        print("  Warning: no volume list variables were patched")


# ─── Horizon ──────────────────────────────────────────────────────────────────

def step_horizon():
    print("\n[7] Horizon settings")

    horizon_dir = '/etc/kolla/config/horizon'
    settings_file = os.path.join(horizon_dir, '_9999-custom-settings.py')

    os.makedirs(horizon_dir, exist_ok=True)

    if os.path.exists(settings_file):
        print(f"  {settings_file} already exists — skipping")
        return

    write_file(settings_file, HORIZON_SETTINGS_CONTENT)
    print(f"  Created {settings_file}")


# ─── Main ─────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description='Automate T4O setup on Kolla-Ansible OpenStack',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        '--os-release', required=True,
        help=f'OpenStack release name ({", ".join(SUPPORTED_RELEASES)})',
    )
    parser.add_argument(
        '--mode', required=True, choices=['install', 'upgrade'],
        help='install = new install, upgrade = existing deployment',
    )
    parser.add_argument(
        '--venv-path', default='/opt/kolla-venv',
        help='Path to kolla-ansible virtualenv (default: /opt/kolla-venv)',
    )
    parser.add_argument(
        '--inventory-file', default='/root/multinode',
        help='Path to kolla inventory file (default: /root/multinode)',
    )
    parser.add_argument(
        '--globals-file', default='/etc/kolla/globals.yml',
        help='Path to /etc/kolla/globals.yml (default: /etc/kolla/globals.yml)',
    )
    return parser.parse_args()


def main():
    args = parse_args()

    os_release = args.os_release.lower()
    mode = args.mode
    venv_path = args.venv_path
    inventory_file = args.inventory_file
    globals_file = args.globals_file

    script_dir = os.path.dirname(os.path.abspath(__file__))
    ansible_dir = os.path.normpath(os.path.join(script_dir, '..'))

    if os_release not in SUPPORTED_RELEASES:
        print(
            f"Warning: '{os_release}' not in known releases {SUPPORTED_RELEASES}.\n"
            "Continuing — ensure the globals/site files exist for this release."
        )

    # Resolve Trilio-side file paths
    trilio_globals = os.path.join(ansible_dir, f'triliovault_globals_{os_release}.yml')
    trilio_site = os.path.join(ansible_dir, f'triliovault_site_{os_release}.yml')
    trilio_inventory = os.path.join(ansible_dir, 'triliovault_inventory.txt')
    passwords_file = '/etc/kolla/passwords.yml'
    site_yml = os.path.join(
        venv_path, 'share', 'kolla-ansible', 'ansible', 'site.yml'
    )

    # Validate required files exist before starting
    required = [
        (globals_file,     'Kolla globals.yml'),
        (passwords_file,   'Kolla passwords.yml'),
        (inventory_file,   'Kolla inventory'),
        (site_yml,         'Kolla site.yml'),
        (trilio_globals,   f'Trilio globals for {os_release}'),
        (trilio_site,      f'Trilio site for {os_release}'),
        (trilio_inventory, 'Trilio inventory'),
    ]
    for path, label in required:
        if not os.path.exists(path):
            die(f"{label} not found: {path}")

    # Create a single timestamped backup directory for this run
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup_dir = os.path.join(os.getcwd(), 'backup', ts)
    os.makedirs(backup_dir, exist_ok=True)

    # Tee all output to prepare_install_upgrade.log in cwd
    log_path = os.path.join(os.getcwd(), LOG_FILE)
    log_fh = open(log_path, 'w', encoding='utf-8')
    sys.stdout = _Tee(sys.__stdout__, log_fh)
    sys.stderr = _Tee(sys.__stderr__, log_fh)

    print("=" * 60)
    print("Trilio Kolla-Ansible Setup")
    print("=" * 60)
    print(f"  OS release    : {os_release}")
    print(f"  Mode          : {mode}")
    print(f"  Venv path     : {venv_path}")
    print(f"  Inventory     : {inventory_file}")
    print(f"  Globals       : {globals_file}")
    print(f"  Backup dir    : {backup_dir}")
    print(f"  Log file      : {log_path}")
    print("=" * 60)

    step_role(script_dir, os_release, venv_path)
    step_globals(globals_file, trilio_globals, mode, backup_dir)
    step_passwords(passwords_file, mode, backup_dir)
    step_site(site_yml, trilio_site, backup_dir)
    step_inventory(inventory_file, trilio_inventory, backup_dir)
    step_nova_cell_volumes(venv_path, backup_dir)
    step_horizon()

    print("\n" + "=" * 60)
    print("Setup complete.")
    print("=" * 60)
    print("\nNext steps:")
    print("  1. Review /etc/kolla/globals.yml")
    print("     Fill in any empty Trilio parameters (credentials, docker login, etc.)")
    if mode == 'install':
        print("     Set: cloud_admin_username, cloud_admin_password,")
        print("          cloud_admin_projectname, cloud_admin_projectid,")
        print("          cloud_admin_domainname, cloud_admin_domainid,")
        print("          triliovault_docker_username, triliovault_docker_password")
        print("  2. docker login to Trilio registry:")
        print("     ansible -i multinode control -m shell \\")
        print("       -a 'docker login -u <user> -p <pass> docker.io' --become")
        print(f"  3. kolla-ansible pull -i {inventory_file} --tags triliovault")
        print(f"  4. kolla-ansible deploy -i {inventory_file} --tags triliovault")
        print("  5. Run wlm_cloud_trust.yml after deployment completes")
    else:
        print(f"  2. kolla-ansible pull -i {inventory_file} --tags triliovault")
        print(f"  3. kolla-ansible upgrade -i {inventory_file} --tags triliovault")

    print(f"\nOutput saved to: {log_path}")
    log_fh.close()
    sys.stdout = sys.__stdout__
    sys.stderr = sys.__stderr__


if __name__ == '__main__':
    main()
