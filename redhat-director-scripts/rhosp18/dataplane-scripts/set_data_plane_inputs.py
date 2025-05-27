#!/usr/bin/python3
import re
import base64
import yaml

YAML_FILE = "../ctlplane-scripts/tvo-operator-inputs.yaml"
SECRET_FILE = "../ctlplane-scripts/trilio-openstack-secret.yaml"
CM_FILE = "cm-trilio-datamover.yaml"

with open(YAML_FILE) as f:
    data = yaml.safe_load(f)
with open(SECRET_FILE) as f:
    secrets = yaml.safe_load(f)

common = data["spec"]["rabbitmq"]["common"]
dmapi = data["spec"]["rabbitmq"]["datamover_api"]
backup_targets = data.get("spec", {}).get("triliovault_backup_targets", [])
backup_targets_yaml = yaml.dump(
    {"triliovault_backup_targets": backup_targets},
    default_flow_style=False,
    indent=2
)


DMAPI_RABBIT_USER = dmapi.get("user", "")
DMAPI_RABBIT_VHOST = dmapi.get("vhost", "")
DMAPI_RABBIT_PASSWORD = dmapi.get("password", "")
OPENSTACK_RABBIT_HOST = common.get("host", "")
DMAPI_RABBIT_PORT = "5671"
DMAPI_RABBIT_SSL = str(common.get("ssl", "false")).lower()

DMAPI_RABBIT_SSL_NUMBER = "1" if DMAPI_RABBIT_SSL == "true" else "0"

# Decode password from Secret
encoded_password = secrets["data"].get("DmapiRabbitPassword", "")
DMAPI_RABBIT_PASSWORD = base64.b64decode(encoded_password).decode("utf-8") if encoded_password else ""


DMAPI_TRANSPORT_URL = (
    f"rabbit://{DMAPI_RABBIT_USER}:{DMAPI_RABBIT_PASSWORD}"
    f"@{OPENSTACK_RABBIT_HOST}:{DMAPI_RABBIT_PORT}"
    f"/{DMAPI_RABBIT_VHOST}?ssl={DMAPI_RABBIT_SSL_NUMBER}"
)

# Database section
db_common = data["spec"]["database"]["common"]
db_dmapi = data["spec"]["database"]["datamover_api"]

DB_USER = db_dmapi.get("user", "")
DB_NAME = db_dmapi.get("database", "")
DB_HOST = db_common.get("host", "")
DB_PORT = db_common.get("port", "3306")

# Decode DB password
encoded_db_pw = secrets["data"].get("DmapiDatabasePassword", "")
DB_PASSWORD = base64.b64decode(encoded_db_pw).decode("utf-8") if encoded_db_pw else ""

DMAPI_DB_CONN = (
    f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}"
    f"@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)


pattern_rabbit = re.compile(r'^(\s*dmapi_transport_url:\s*")[^"]*(")')
pattern_db = re.compile(r'^(\s*dmapi_database_connection:\s*")[^"]*(")')

# Update file
with open(CM_FILE, 'r') as f:
    lines = f.readlines()

with open(CM_FILE, 'w') as f:
    for line in lines:
        line = pattern_rabbit.sub(rf'\1{DMAPI_TRANSPORT_URL}\2', line)
        line = pattern_db.sub(rf'\1{DMAPI_DB_CONN}\2', line)
        f.write(line)

print("Updated dmapi database connection and dmapi rabbit transport url in file cm-trilio-datamover.yaml")


# Step 1: Trim all lines after 'triliovault_backup_targets:'
trimmed_lines = []
found = False
with open(CM_FILE, "r") as f:
    for line in f:
        trimmed_lines.append(line)
        if "triliovault_backup_targets:" in line:
            found = True
            break  # stop after this line

if not found:
    print("triliovault_backup_targets: not found in the file.")
    exit(1)

# Step 2: Write trimmed content back
with open(CM_FILE, "w") as f:
    f.writelines(trimmed_lines)


# Step 4: Append with proper indentation (6 spaces for trilio_env.yml nesting)
with open(CM_FILE, "a") as f:
    for line in backup_targets_yaml.splitlines()[1:]:  # Skip the top-level key
        f.write("      " + line + "\n")

print("Updated triliovault backup targets cm-trilio-datamover.yaml")