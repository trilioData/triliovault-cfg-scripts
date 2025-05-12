#!/usr/bin/python3
import subprocess
import yaml
import sys
from urllib.parse import urlparse
import secrets
import string
import re
import base64


# Define the input YAML file
yaml_file = "tvo-operator-inputs.yaml"

# Function to check if Barbican is installed
def is_barbican_installed():
    try:
        print("Checking if Barbican is installed...")
        result = subprocess.run(
            ["oc", "rsh", "-n", "openstack", "openstackclient", "openstack", "endpoint", "list", "--service", "barbican"],
            capture_output=True,
            text=True,
            check=True
        )
        installed = "barbican" in result.stdout.lower()
        print("Barbican installed." if installed else "Barbican not installed.")
        return installed
    except subprocess.CalledProcessError:
        print("Failed to check Barbican installation.")
        return False

def get_memcached_servers():
    try:
        print("Fetching memcached servers...")
        result = subprocess.run(
            ["oc", "-n", "openstack", "get", "memcached", "-o", "jsonpath={.items[*].status.serverList[*]}"],
            capture_output=True,
            text=True,
            check=True
        )
        memcached_servers = result.stdout.strip().replace(" ", ",")
        return memcached_servers
    except subprocess.CalledProcessError:
        print("Failed to fetch memcached servers.")
        return ""

# New function to extract keystone_interface from YAML
def get_keystone_interface(yaml_data):
    try:
        return yaml_data["spec"]["keystone"]["keystone_interface"]
    except KeyError:
        print("keystone_interface not found in YAML. Defaulting to 'internal'.")
        return "internal"

# Updated function to fetch Keystone URL dynamically
def get_keystone_url_by_interface(interface):
    try:
        print(f"Fetching Keystone URL for interface '{interface}' from openstackclient pod...")
        result = subprocess.run(
            [
                "oc", "rsh", "-n", "openstack", "openstackclient",
                "openstack", "endpoint", "list",
                "-f", "value", "-c", "Service Name", "-c", "Interface", "-c", "URL"
            ],
            capture_output=True,
            text=True,
            check=True
        )

        for line in result.stdout.strip().splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3:
                service, iface, url = parts
                if service.lower() == "keystone" and iface.lower() == interface.lower():
                    return url.strip()

        print(f"Keystone endpoint with interface '{interface}' not found.")
        return ""
    except subprocess.CalledProcessError as e:
        print("Failed to retrieve Keystone endpoint:", e)
        return ""

# Function to fetch the public endpoint for Glance and extract the cluster domain
def fetch_and_extract_cluster_domain():
    try:
        print("Fetching Glance public endpoint...")
        result = subprocess.run(
            ["oc", "rsh", "-n", "openstack", "openstackclient", "openstack", "endpoint", "list", "--service", "image", "-f", "value", "-c", "URL", "--interface", "public"],
            capture_output=True,
            text=True,
            check=True
        )
        glance_url = result.stdout.strip()
        
        if glance_url:
            
            # Match everything after "openstack." and before the next "/"
            match = re.search(r'openstack\.(.+?)(?:[/:]|$)', glance_url)
            if match:
                cluster_domain = match.group(1)
                return glance_url, cluster_domain
            else:
                print("Failed to extract cluster domain.")
                return None, None
        else:
            print("No Glance public endpoint found.")
            return None, None
    except subprocess.CalledProcessError as e:
        print(f"Failed to fetch Glance endpoint: {e}")
        return None, None

# Function to update keystone endpoints for trilio services
def update_keystone_endpoints():
    glance_url, cluster_domain = fetch_and_extract_cluster_domain()
    
    if glance_url and cluster_domain:
        keystone_endpoints = {
            "datamover_api": {
                "internal_endpoint": f"https://triliovault-datamover-internal.trilio-openstack.svc:8784/v2",
                "public_endpoint": f"https://triliovault-datamover-public-trilio-openstack.{cluster_domain}/v2"
            },
            "wlm_api": {
                "internal_endpoint": f"https://triliovault-wlm-internal.trilio-openstack.svc:8781/v1/$(tenant_id)s",
                "public_endpoint": f"https://triliovault-wlm-public-trilio-openstack.{cluster_domain}/v1/$(tenant_id)s"
                }
        }
        
    else:
        print("Unable to update Keystone endpoints, missing necessary information.")




# Get the image tag from command-line argument
if len(sys.argv) != 2:
    print("Usage: script.py <image-tag>")
    sys.exit(1)

image_tag = sys.argv[1]

# Load the YAML file
print("Loading YAML file...")
with open(yaml_file, "r") as file:
    yaml_data = yaml.safe_load(file)

# Determine the new value for trustee_role
new_trustee_role = "creator,member" if is_barbican_installed() else "member"

# Update trustee_role while preserving structure
if "spec" in yaml_data and "common" in yaml_data["spec"]:
    yaml_data["spec"]["common"]["trustee_role"] = new_trustee_role
    print(f"- Updated trustee_role to: {new_trustee_role}")

# Update image tags
if "spec" in yaml_data and "images" in yaml_data["spec"]:
    for key in yaml_data["spec"]["images"]:
        base_image = yaml_data["spec"]["images"][key].split(":")[0]
        yaml_data["spec"]["images"][key] = f"{base_image}:{image_tag}"
    print(f"- Updated all image tags to: {image_tag}")



# Update memcached_servers
memcached_servers = get_memcached_servers()
if memcached_servers and "spec" in yaml_data and "common" in yaml_data["spec"]:
    yaml_data["spec"]["common"]["memcached_servers"] = memcached_servers
    print("- Updated common.memcached_servers.")


# Get keystone_interface from YAML
keystone_interface = get_keystone_interface(yaml_data)

# Fetch Keystone URL for the specified interface
keystone_url = get_keystone_url_by_interface(keystone_interface)
if keystone_url:
    parsed = urlparse(keystone_url)
    keystone_common = {
        "auth_url": f"{parsed.scheme}://{parsed.hostname}:{parsed.port}",
        "auth_uri": keystone_url,
        "keystone_auth_protocol": parsed.scheme,
        "keystone_auth_host": parsed.hostname,
        "keystone_auth_port": str(parsed.port)
    }

    if "spec" in yaml_data:
        yaml_data.setdefault("spec", {}).setdefault("keystone", {}).setdefault("common", {}).update(keystone_common)
        print("- Updated keystone.common with auth details.")



## Set rabbitmq params
def set_rabbitmq_params():
    try:
        # Fetch RabbitMQ admin user
        result = subprocess.run(
            ["oc", "-n", "openstack", "exec", "rabbitmq-server-0", "--", "bash", "-c", "rabbitmqctl list_users"],
            capture_output=True, text=True, check=True
        )
        # Parse the output to get the admin user
        rabbit_admin_user = None
        for line in result.stdout.splitlines():
            if "administrator" in line:
                rabbit_admin_user = line.split()[0]
                break
        if not rabbit_admin_user:
            raise Exception("Administrator user not found in RabbitMQ")

        # Fetch RabbitMQ admin password
        result = subprocess.run(
            ["oc", "-n", "openstack", "get", "secret", "rabbitmq-default-user", "-o", "jsonpath='{.data.password}'"],
            capture_output=True, text=True, check=True
        )
        rabbit_admin_password = base64.b64decode(result.stdout.strip().strip("'")).decode("utf-8")

        # Fetch RabbitMQ host
        result = subprocess.run(
            ["oc", "-n", "openstack", "get", "secret", "rabbitmq-default-user", "-o", "jsonpath='{.data.host}'"],
            capture_output=True, text=True, check=True
        )
        rabbit_host = base64.b64decode(result.stdout.strip().strip("'")).decode("utf-8")

        result = subprocess.run(
            ["oc", "-n", "openstack", "get", "cm", "rabbitmq-server-conf", "-o", "jsonpath={.data.userDefinedConfiguration\\.conf}"],
            capture_output=True, text=True, check=True
        )

        # Extract management.ssl.port using regex
        match = re.search(r'management\.ssl\.port\s*=\s*(\d+)', result.stdout)

        if match:
            rabbit_port = match.group(1)
        else:
            print("management.ssl.port not found.")
        listener_match = re.search(r'listeners\.ssl\.default\s*=\s*(\d+)', result.stdout)
        rabbit_listener_port = listener_match.group(1) if listener_match else None
        # Assuming SSL is enabled
        rabbit_ssl = True

        yaml_data["spec"]["rabbitmq"]["common"]["admin_user"] = rabbit_admin_user
        yaml_data["spec"]["rabbitmq"]["common"]["admin_password"] = rabbit_admin_password
        yaml_data["spec"]["rabbitmq"]["common"]["host"] = rabbit_host
        yaml_data["spec"]["rabbitmq"]["common"]["port"] = rabbit_port
        rabbit_dmapi_password = yaml_data["spec"]["rabbitmq"]["datamover_api"]["password"]
        rabbit_dmapi_vhost = yaml_data["spec"]["rabbitmq"]["datamover_api"]["vhost"]
        rabbit_dmapi_user = yaml_data["spec"]["rabbitmq"]["datamover_api"]["user"]
        yaml_data["spec"]["rabbitmq"]["datamover_api"]["transport_url"] = f"rabbit://{rabbit_dmapi_user}:{rabbit_dmapi_password}@{rabbit_host}:{rabbit_listener_port}/{rabbit_dmapi_vhost}?ssl=1"
        rabbit_wlmapi_password = yaml_data["spec"]["rabbitmq"]["wlm_api"]["password"]
        rabbit_wlmapi_vhost = yaml_data["spec"]["rabbitmq"]["wlm_api"]["vhost"]
        rabbit_wlmapi_user = yaml_data["spec"]["rabbitmq"]["wlm_api"]["user"]
        yaml_data["spec"]["rabbitmq"]["wlm_api"]["transport_url"] = f"rabbit://{rabbit_wlmapi_user}:{rabbit_wlmapi_password}@{rabbit_host}:{rabbit_listener_port}/{rabbit_wlmapi_vhost}?ssl=1"

        print("- Updated rabbitmq section with admin, host, and transport URLs.")

    except subprocess.CalledProcessError as e:
        print(f"Error during RabbitMQ parameter fetch: {e}")
    except Exception as e:
        print(f"Error: {e}")



# Function to generate a secure 32-character random password
def generate_password(length=32):
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))

# Generate individual passwords
keystone_wlm_pw = generate_password()
keystone_dmapi_pw = generate_password()
rabbitmq_wlm_pw = generate_password()
rabbitmq_dmapi_pw = generate_password()
db_wlm_pw = generate_password()
db_dmapi_pw = generate_password()

# Update Keystone passwords
try:
    yaml_data["spec"]["keystone"]["wlm_api"]["password"] = keystone_wlm_pw
    print("- Updated keystone.wlm_api.password.")
except KeyError:
    print("Warning: keystone.wlm_api section not found.")

try:
    yaml_data["spec"]["keystone"]["datamover_api"]["password"] = keystone_dmapi_pw
    print("- Updated keystone.datamover_api.password.")
except KeyError:
    print("Warning: keystone.datamover_api section not found.")

# Update RabbitMQ passwords
try:
    yaml_data["spec"]["rabbitmq"]["wlm_api"]["password"] = rabbitmq_wlm_pw
    print("- Updated rabbitmq.wlm_api.password.")
except KeyError:
    print("Warning: rabbitmq.wlm_api section not found.")

try:
    yaml_data["spec"]["rabbitmq"]["datamover_api"]["password"] = rabbitmq_dmapi_pw
    print("- Updated rabbitmq.datamover_api.password.")
except KeyError:
    print("Warning: rabbitmq.datamover_api section not found.")

# Update Database passwords
try:
    yaml_data["spec"]["database"]["wlm_api"]["password"] = db_wlm_pw
    print("- Updated database.wlm_api.password.")
except KeyError:
    print("Warning: database.wlm_api section not found.")

try:
    yaml_data["spec"]["database"]["datamover_api"]["password"] = db_dmapi_pw
    print("- Updated database.datamover_api.password.")
except KeyError:
    print("Warning: database.datamover_api section not found.")



update_keystone_endpoints()
print("Calling rabbit params method")
set_rabbitmq_params()

# Write back to YAML file
with open(yaml_file, "w") as file:
    yaml.dump(yaml_data, file, default_flow_style=False, sort_keys=False)


print("YAML file tvo-operator-inputs.yaml is updated successfully.")

