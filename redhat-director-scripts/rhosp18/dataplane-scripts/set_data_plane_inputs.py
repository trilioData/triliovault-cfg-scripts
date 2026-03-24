#!/usr/bin/python3
import yaml

def str_presenter(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar(
            "tag:yaml.org,2002:str",
            data,
            style="|"
        )
    return dumper.represent_scalar(
        "tag:yaml.org,2002:str",
        data
    )

yaml.add_representer(str, str_presenter)

YAML_FILE = "../ctlplane-scripts/tvo-operator-inputs.yaml"
SECRET_FILE = "../ctlplane-scripts/trilio-openstack-secret.yaml"
CM_FILE = "cm-trilio-datamover.yaml"

# Load YAML files
with open(YAML_FILE) as f:
    data = yaml.safe_load(f)
with open(SECRET_FILE) as f:
    secrets = yaml.safe_load(f)

# Extract data
rabbit_host = data["spec"]["rabbitmq"]["common"].get("host", "")
rabbit_ssl = data["spec"]["rabbitmq"]["common"].get("ssl", True)
rabbit_quorum_queue = data["spec"]["rabbitmq"]["cluster"].get("rabbit_quorum_queue", False)
database_host = data["spec"]["database"]["common"].get("host", "")
database_port = data["spec"]["database"]["common"].get("port", "3306")
keystone_auth_url = data["spec"]["keystone"]["common"].get("auth_url", "")
keystone_ssl_verify = data["spec"]["keystone"]["common"].get("ssl_verify", True)
backup_targets = data.get("spec", {}).get("triliovault_backup_targets", [])
dms_image = data["spec"]["images"].get("triliovault_dms", "")
wlm_image = data["spec"]["images"].get("triliovault_wlm", "")

# Format new YAML block for backup targets
backup_targets_yaml = yaml.dump(
    {"triliovault_backup_targets": backup_targets},
    default_flow_style=False,
    indent=2,
    sort_keys=False,
    allow_unicode=True,
    width=float("inf")
)

# Read and update lines before backup targets
updated_lines = []
with open(CM_FILE, "r") as f:
    for line in f:
        if "triliovault_backup_targets:" in line:
            break
        if "rabbit_host:" in line:
            updated_lines.append(f'    rabbit_host: "{rabbit_host}"\n')
        elif "rabbit_ssl:" in line:
            updated_lines.append(f'    rabbit_ssl: {str(rabbit_ssl).lower()}\n')
        elif "rabbit_quorum_queue:" in line:
            updated_lines.append(f'    rabbit_quorum_queue: {str(rabbit_quorum_queue).lower()}\n')
        elif "database_host:" in line:
            updated_lines.append(f'    database_host: "{database_host}"\n')
        elif "database_port:" in line:
            updated_lines.append(f'    database_port: "{database_port}"\n')
        elif "keystone_auth_url:" in line:
            updated_lines.append(f'    keystone_auth_url: "{keystone_auth_url}"\n')
        elif "keystone_ssl_verify:" in line:
            updated_lines.append(f'    keystone_ssl_verify: {str(keystone_ssl_verify).lower()}\n')
        elif "triliovault_dms_image:" in line:
            updated_lines.append(f'    triliovault_dms_image: "{dms_image}"\n')
        elif "triliovault_wlm_image:" in line:
            updated_lines.append(f'    triliovault_wlm_image: "{wlm_image}"\n')
        else:
            updated_lines.append(line)

# Write updated header lines back
with open(CM_FILE, "w") as f:
    f.writelines(updated_lines)

# Append backup targets with proper indentation (6 spaces under trilio_env.yml)
with open(CM_FILE, "a") as f:
    lines = backup_targets_yaml.splitlines()
    if lines:
        # Write the key with 4 spaces
        f.write("    " + lines[0] + "\n")  # 'triliovault_backup_targets:'
        # Write the list items with 6 spaces
        for line in lines[1:]:
            f.write("      " + line + "\n")

print("Updated rabbit/database/keystone config, image URLs, and backup targets in cm-trilio-datamover.yaml")
