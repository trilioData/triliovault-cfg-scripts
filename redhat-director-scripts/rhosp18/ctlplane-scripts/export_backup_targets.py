#!/usr/bin/env python3
"""
export_backup_targets.py

Reads backup target configurations from a T4O 6.0/6.1 RHOSO18 installation
and writes them to a migration YAML file for use with create_backup_targets_62.py.

Sources:
  1. tvo-operator-inputs.yaml  -- static backup targets (triliovault_backup_targets list)
  2. TVOBackupTarget CRs       -- dynamic backup targets added via operator

For each S3 backup target, credentials are read from the K8s secrets:
  - Multi-BT mode : trilio-openstack-secret
                    keys: <bt_name>_s3_access_key, <bt_name>_s3_secret_key
  - Single-BT mode: trilio-s3-backup-target-secret-<bt_name_lower_dashes>
                    keys: <bt_name>_s3_access_key, <bt_name>_s3_secret_key

Usage:
  python3 export_backup_targets.py [options]

Options:
  --inputs-file   Path to tvo-operator-inputs.yaml  (default: tvo-operator-inputs.yaml)
  --namespace     OpenShift namespace                (default: trilio-openstack)
  --output        Output migration YAML file         (default: backup-targets-migration.yaml)

Prerequisites:
  - oc CLI logged in with sufficient RBAC to read secrets in trilio-openstack namespace
  - PyYAML installed  (pip install pyyaml  or  dnf install python3-pyyaml)
"""

import argparse
import base64
import json
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required.  Install with:  dnf install python3-pyyaml", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run_oc(args, namespace=None):
    """Run an oc command and return stdout, or None on failure."""
    cmd = ["oc"]
    if namespace:
        cmd += ["-n", namespace]
    cmd += args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def decode_secret_key(namespace, secret_name, key):
    """Return the base64-decoded value of a key in a K8s secret, or None."""
    # Escape dots in key for jsonpath
    safe_key = key.replace(".", "\\.")
    raw = run_oc(["get", "secret", secret_name,
                  "-o", f"jsonpath={{.data.{safe_key}}}"], namespace=namespace)
    if not raw:
        return None
    try:
        return base64.b64decode(raw).decode("utf-8").strip()
    except Exception:
        return None


def read_s3_credentials(namespace, bt_name):
    """
    Try to read S3 access/secret keys for a backup target.
    Tries per-BT secret first, then falls back to the shared trilio-openstack-secret.
    Returns (access_key, secret_key) — empty strings if not found.
    """
    key_access = f"{bt_name}_s3_access_key"
    key_secret = f"{bt_name}_s3_secret_key"

    # Single-BT mode: trilio-s3-backup-target-secret-<bt_name_lower_dashes>
    per_bt_secret = "trilio-s3-backup-target-secret-" + bt_name.lower().replace("_", "-")
    access_key = decode_secret_key(namespace, per_bt_secret, key_access)
    secret_key = decode_secret_key(namespace, per_bt_secret, key_secret)

    if access_key and secret_key:
        print(f"      Credentials from secret: {per_bt_secret}")
        return access_key, secret_key

    # Multi-BT mode: trilio-openstack-secret
    access_key = decode_secret_key(namespace, "trilio-openstack-secret", key_access)
    secret_key = decode_secret_key(namespace, "trilio-openstack-secret", key_secret)

    if access_key and secret_key:
        print(f"      Credentials from secret: trilio-openstack-secret")
        return access_key, secret_key

    print(f"      WARNING: S3 credentials not found for '{bt_name}'. "
          "Set s3_access_key/s3_secret_key manually in the output file.")
    return "", ""


def normalize_backup_target(bt_raw, namespace):
    """
    Normalise a raw backup target dict (from inputs YAML or CR spec) into
    a consistent format for the migration YAML.
    """
    bt_type = bt_raw.get("backup_target_type", "")
    bt_name = bt_raw.get("backup_target_name", "")

    entry = {
        "backup_target_name": bt_name,
        "backup_target_type": bt_type,
        "is_default": bool(bt_raw.get("is_default", False)),
    }

    if bt_type == "s3":
        entry.update({
            "s3_type":                     bt_raw.get("s3_type", "amazon_s3"),
            "s3_bucket":                   bt_raw.get("s3_bucket", ""),
            "s3_endpoint_url":             bt_raw.get("s3_endpoint_url", ""),
            "s3_region_name":              bt_raw.get("s3_region_name", ""),
            "s3_signature_version":        bt_raw.get("s3_signature_version", "default"),
            "s3_auth_version":             bt_raw.get("s3_auth_version", "DEFAULT"),
            "s3_ssl_enabled":              bool(bt_raw.get("s3_ssl_enabled", True)),
            "s3_ssl_verify":               bool(bt_raw.get("s3_ssl_verify", True)),
            "s3_self_signed_cert":         bool(bt_raw.get("s3_self_signed_cert", False)),
            "s3_bucket_object_lock_enabled": bool(bt_raw.get("s3_bucket_object_lock_enabled", False)),
        })
        if bt_raw.get("s3_ssl_ca_cert"):
            entry["s3_ssl_ca_cert"] = bt_raw["s3_ssl_ca_cert"]
        access_key, secret_key = read_s3_credentials(namespace, bt_name)
        entry["s3_access_key"] = access_key
        entry["s3_secret_key"] = secret_key

    elif bt_type == "nfs":
        entry.update({
            "nfs_shares":  bt_raw.get("nfs_shares", ""),
            "nfs_options": bt_raw.get("nfs_options", ""),
        })

    return entry


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Export T4O 6.0/6.1 backup targets to a migration YAML for T4O 6.2"
    )
    parser.add_argument(
        "--inputs-file", default="tvo-operator-inputs.yaml",
        help="Path to tvo-operator-inputs.yaml (default: tvo-operator-inputs.yaml)"
    )
    parser.add_argument(
        "--namespace", default="trilio-openstack",
        help="OpenShift namespace (default: trilio-openstack)"
    )
    parser.add_argument(
        "--output", default="backup-targets-migration.yaml",
        help="Output file (default: backup-targets-migration.yaml)"
    )
    args = parser.parse_args()

    backup_targets = []
    seen_names = set()

    # ------------------------------------------------------------------
    # Source 1: tvo-operator-inputs.yaml (static backup targets)
    # ------------------------------------------------------------------
    print(f"\n[1/2] Reading static backup targets from: {args.inputs_file}")
    try:
        with open(args.inputs_file) as f:
            inputs_doc = yaml.safe_load(f)

        # Handle both top-level and spec-nested formats
        spec = inputs_doc.get("spec", inputs_doc)
        static_bts = spec.get("triliovault_backup_targets", [])

        if not static_bts:
            print("  No triliovault_backup_targets found in inputs file.")
        else:
            for bt_raw in static_bts:
                name = bt_raw.get("backup_target_name", "")
                bt_type = bt_raw.get("backup_target_type", "")
                print(f"  Found: {name}  (type: {bt_type})")
                if name in seen_names:
                    print(f"    Skipping duplicate: {name}")
                    continue
                seen_names.add(name)
                backup_targets.append(normalize_backup_target(bt_raw, args.namespace))

    except FileNotFoundError:
        print(f"  WARNING: {args.inputs_file} not found. Skipping static backup targets.")
    except yaml.YAMLError as e:
        print(f"  ERROR: Failed to parse {args.inputs_file}: {e}", file=sys.stderr)

    # ------------------------------------------------------------------
    # Source 2: TVOBackupTarget CRs (dynamic backup targets)
    # ------------------------------------------------------------------
    print(f"\n[2/2] Reading dynamic backup targets from TVOBackupTarget CRs "
          f"in namespace '{args.namespace}'")
    cr_json = run_oc(["get", "tvobackuptarget", "-o", "json"], namespace=args.namespace)
    if cr_json:
        try:
            cr_data = json.loads(cr_json)
            items = cr_data.get("items", [])
            if not items:
                print("  No TVOBackupTarget CRs found.")
            for item in items:
                cr_name = item.get("metadata", {}).get("name", "")
                bt_raw = item.get("spec", {}).get("triliovault_backup_target", {})
                name = bt_raw.get("backup_target_name", "")
                bt_type = bt_raw.get("backup_target_type", "")
                if not name:
                    print(f"  WARNING: CR '{cr_name}' has no backup_target_name. Skipping.")
                    continue
                print(f"  Found: {name}  (type: {bt_type}, CR: {cr_name})")
                if name in seen_names:
                    print(f"    Skipping duplicate: {name}")
                    continue
                seen_names.add(name)
                backup_targets.append(normalize_backup_target(bt_raw, args.namespace))
        except json.JSONDecodeError as e:
            print(f"  ERROR: Failed to parse TVOBackupTarget CR output: {e}", file=sys.stderr)
    else:
        print("  No TVOBackupTarget CRs found or oc command failed.")

    # ------------------------------------------------------------------
    # Write output
    # ------------------------------------------------------------------
    if not backup_targets:
        print("\nNo backup targets found. Nothing to export.")
        sys.exit(0)

    output_doc = {"backup_targets": backup_targets}
    with open(args.output, "w") as f:
        yaml.dump(output_doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

    print(f"\nExported {len(backup_targets)} backup target(s) to: {args.output}")
    print("\nNext steps:")
    print(f"  1. Review {args.output} and verify all values (especially S3 credentials).")
    print("  2. Source your OpenStack cloudrc file.")
    print("  3. Run:  python3 create_backup_targets_62.py")
