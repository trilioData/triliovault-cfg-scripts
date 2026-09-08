#!/usr/bin/python3
import re
import shutil
import subprocess
import sys


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
# obsolete fields - it does NOT change the value of any parameter that survives the fix,
# and it does not reformat/reserialize the rest of the file: removal is done line-by-line
# on the original text (tracking indentation to find each field and its nested block, if
# any), so every other line - including comments, quote style, and boolean literal casing -
# is left byte-for-byte unchanged. Run it once as part of upgrading to the TVAULT-7511 fix,
# after the RabbitMQ CR/PVC cleanup (if applicable) and the tvo-operator image upgrade.
#
# spec.images.rabbitmq is deliberately NOT in this list. It was originally removed here,
# on the assumption that the native CRD had no image field - it does
# (spec.containerImage), and leaving it unset makes the operator fall back to the upstream
# community image. Stripping the key would therefore downgrade an upgrading customer from
# RHOSO's supported RabbitMQ image to quay.io/podified-antelope-centos9. The FR5 and FR6
# inputs files both carry the key, and the FR6 chart consumes it, so it must survive.
#
# spec.rabbitmq.cluster.rabbitmq IS deliberately still in this list, even though the
# native CRD does support spec.rabbitmq.additionalConfig (TVAULT-7678). The FR6 chart
# reads its broker tuning from spec.rabbitmq.cluster.additional_config - a separate key
# - precisely so that a leftover FR5 block here can never reach the native CR: the FR5
# block carries cluster_partition_handling = autoheal and ssl_options.*, which would
# override the FR6 operator's own pause_minority and TLS listener setup, and
# advanced_config/erlang_inet_config, which would replace its FIPS-/version-aware TLS
# config and break DNS resolution. So on FR6 this block is inert whether or not it is
# removed; stripping it keeps the file honest. The chart's own default supplies the
# equivalent tuning, and main() warns if the block being removed was customised.

FIELDS_TO_REMOVE = [
    ("spec", "rabbitmq", "cluster", "api_version"),
    ("spec", "rabbitmq", "cluster", "tls"),
    ("spec", "rabbitmq", "cluster", "rabbitmq"),
    ("spec", "rabbitmq", "cluster", "service"),
    ("spec", "rabbitmq", "cluster", "affinity"),
]

KEY_LINE_RE = re.compile(r"^( *)(?:- )?([A-Za-z0-9_.-]+):(?:\s|$)")


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


def line_indent(line):
    match = KEY_LINE_RE.match(line)
    if not match:
        return None
    indent = len(match.group(1))
    if "- " in line[:indent + 2]:
        indent += 2
    return indent


def strip_fields(lines, fields_to_remove):
    remaining = {path: True for path in fields_to_remove}
    output = []
    stack = []  # list of (indent, key)
    removing_below_indent = None

    for line in lines:
        match = KEY_LINE_RE.match(line)
        indent = line_indent(line)

        if removing_below_indent is not None:
            if indent is not None and indent <= removing_below_indent:
                removing_below_indent = None
            else:
                continue

        if indent is None:
            output.append(line)
            continue

        while stack and stack[-1][0] >= indent:
            stack.pop()

        key = match.group(2)
        current_path = tuple(k for _, k in stack) + (key,)
        stack.append((indent, key))

        if current_path in remaining:
            remaining[current_path] = False
            removing_below_indent = indent
            continue

        output.append(line)

    return output, [path for path, still_present in remaining.items() if not still_present]


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

    with open(input_file, "r", newline="") as file:
        lines = file.readlines()

    output_lines, removed_paths = strip_fields(lines, FIELDS_TO_REMOVE)

    for path in FIELDS_TO_REMOVE:
        dotted = ".".join(path)
        print(f"- Removed {dotted}" if path in removed_paths else f"- {dotted} not present, skipping")

    if ("spec", "rabbitmq", "cluster", "rabbitmq") in removed_paths:
        print()
        print("NOTE: the removed spec.rabbitmq.cluster.rabbitmq block was the till-FR5")
        print("      broker config. On FR6 the chart reads")
        print("      spec.rabbitmq.cluster.additional_config instead and ships the same")
        print("      connection, message-size, heartbeat and GC limits as its default,")
        print("      so a stock block needs no action.")
        print("      If you had CUSTOMISED any value in it (a larger max_message_size or")
        print("      consumer_timeout, say), re-express just those keys under")
        print("      spec.rabbitmq.cluster.additional_config - the original block is")
        print(f"      preserved in {backup_file} for reference.")

    with open(output_file, "w", newline="") as file:
        file.writelines(output_lines)

    print(f"YAML file {output_file} is updated successfully.")


if __name__ == "__main__":
    main()
