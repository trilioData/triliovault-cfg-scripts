import subprocess
import yaml
import sys
from urllib.parse import urlparse
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
        print(f"Memcached servers: {memcached_servers}")
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
                    print(f"Found Keystone URL: {url}")
                    return url.strip()

        print(f"Keystone endpoint with interface '{interface}' not found.")
        return ""
    except subprocess.CalledProcessError as e:
        print("Failed to retrieve Keystone endpoint:", e)
        return ""


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
print(f"Keystone url returned: {keystone_url}")
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

# Write back to YAML file
with open(yaml_file, "w") as file:
    yaml.dump(yaml_data, file, default_flow_style=False, sort_keys=False)


print("YAML file tvo-operator-inputs.yaml is updated successfully.")

