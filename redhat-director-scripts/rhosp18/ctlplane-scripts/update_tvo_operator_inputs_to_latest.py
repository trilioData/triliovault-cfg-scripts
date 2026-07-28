#!/usr/bin/python3
import re
import shutil
import subprocess
import sys
from ruamel.yaml import YAML


# TVAULT-7511: RHOSO switched RabbitMQ from the upstream community RabbitMQ Cluster
# Operator to its own native operator starting with FR6 (18.0.21). The native operator's
# RabbitMq CRD doesn't use several fields the old community-operator template relied on
# (they're either irrelevant to the native CRD or handled by the platform itself), so this
# fix's tvo-operator-inputs-fr6-onwards.yaml drops them. On a cluster still on FR5 or
# earlier, the old community operator is still in use and still needs those fields, so
# this script only strips them when the target cluster is actually on FR6+.
#
# This script patches an existing tvo-operator-inputs.yaml (a customer's real file from
# before this fix, already populated with their own values) by removing exactly those
# obsolete fields - it does NOT change the value of any parameter that survives the fix.
# Run it once as part of upgrading to the TVAULT-7511 fix, after the RabbitMQ CR/PVC
# cleanup (if applicable) and the tvo-operator image upgrade.

FIELDS_TO_REMOVE = [
    ("spec", "images", "rabbitmq"),
    ("spec", "rabbitmq", "cluster", "api_version"),
    ("spec", "rabbitmq", "cluster", "tls"),
    ("spec", "rabbitmq", "cluster", "rabbitmq"),
    ("spec", "rabbitmq", "cluster", "service"),
    ("spec", "rabbitmq", "cluster", "affinity"),
]


def is_fr6_onwards():
    try:
        result = subprocess.run(
            ["oc", "get", "openstackversion", "openstack-controlplane", "-n", "openstack",
             "-o", "jsonpath={.status.deployedVersion}"],
            capture_output=True,
            text=True,
            check=True
        )
        deployed_version = result.stdout.strip()
        match = re.match(r"^(\d+)\.(\d+)\.(\d+)", deployed_version)
        if not match:
            print(f"Could not parse OpenStack version from '{deployed_version}'. Assuming till-FR5, no changes made.")
            return False
        patch = int(match.group(3))
        if patch >= 21:
            print(f"Detected OpenStack version: {deployed_version} (>=18.0.21, FR6 onwards)")
            return True
        print(f"Detected OpenStack version: {deployed_version} (<18.0.21, till FR5) - no changes needed")
        return False
    except subprocess.CalledProcessError:
        print("Failed to detect OpenStack version. Assuming till-FR5, no changes made.")
        return False


def remove_field(yaml_data, path):
    node = yaml_data
    for key in path[:-1]:
        if not isinstance(node, dict) or key not in node:
            return False
        node = node[key]
    last_key = path[-1]
    if isinstance(node, dict) and last_key in node:
        del node[last_key]
        return True
    return False


def main():
    if len(sys.argv) not in (2, 3):
        print("Usage: ./update_tvo_operator_inputs_to_latest.py <input-file> [output-file]")
        print("       If output-file is omitted, input-file is updated in place.")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) == 3 else input_file

    if not is_fr6_onwards():
        print("Target cluster is on till-FR5 - the old community-operator fields are still "
              "required, so the file is left unchanged.")
        sys.exit(0)

    backup_file = f"{input_file}.bak"
    shutil.copy2(input_file, backup_file)
    print(f"- Backed up original file to {backup_file}")

    yaml_parser = YAML()
    yaml_parser.preserve_quotes = True
    yaml_parser.width = 4096
    yaml_parser.indent(mapping=2, sequence=4, offset=2)

    with open(input_file, "r") as file:
        yaml_data = yaml_parser.load(file)

    for path in FIELDS_TO_REMOVE:
        removed = remove_field(yaml_data, path)
        dotted = ".".join(path)
        print(f"- Removed {dotted}" if removed else f"- {dotted} not present, skipping")

    with open(output_file, "w") as file:
        yaml_parser.dump(yaml_data, file)

    print(f"YAML file {output_file} is updated successfully.")


if __name__ == "__main__":
    main()
