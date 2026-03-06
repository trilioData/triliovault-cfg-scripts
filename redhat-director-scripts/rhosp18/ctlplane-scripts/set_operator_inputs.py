#!/usr/bin/python3
import subprocess
from ruamel.yaml import YAML


import sys
from urllib.parse import urlparse
import secrets
import string
import re
import base64


# Define the input YAML file
yaml_file = "tvo-operator-inputs.yaml"

yaml_parser = YAML()
yaml_parser.preserve_quotes = True
yaml_parser.width = 4096

with open(yaml_file, "r") as file:
    yaml_data = yaml_parser.load(file)


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
                "public_endpoint": f"https://triliovault-datamover-public-trilio-openstack.{cluster_domain}/v2",
                "public_auth_host": f"triliovault-datamover-public-trilio-openstack.{cluster_domain}"
            },
            "wlm_api": {
                "public_endpoint": f"https://triliovault-wlm-public-trilio-openstack.{cluster_domain}/v1/$(tenant_id)s",
                "public_auth_host": f"triliovault-wlm-public-trilio-openstack.{cluster_domain}"
                }
        }

        yaml_data["spec"]["keystone"]["datamover_api"]["public_endpoint"] = keystone_endpoints["datamover_api"]["public_endpoint"]
        yaml_data["spec"]["keystone"]["datamover_api"]["public_auth_host"] = keystone_endpoints["datamover_api"]["public_auth_host"]
        yaml_data["spec"]["keystone"]["wlm_api"]["public_endpoint"] = keystone_endpoints["wlm_api"]["public_endpoint"]
        yaml_data["spec"]["keystone"]["wlm_api"]["public_auth_host"] = keystone_endpoints["wlm_api"]["public_auth_host"]

    else:
        print("Unable to update Keystone endpoints, missing necessary information.")




# Get the image tag from command-line argument
if len(sys.argv) != 2:
    print("Usage: ./set_operator_inputs.py <TRILIO-CONTAINER-IMAGE-TAG>")
    print("       Please provide container image tag of trilio-wlm or trilio-datamover-api.")
    print("       If tags of trilio-wlm and trilio-datamover-api does not match then you need to manually set them in tvo-operator-inputs.yaml")
    sys.exit(1)

image_tag = sys.argv[1]

# Determine the new value for trustee_role
new_trustee_role = "creator,member" if is_barbican_installed() else "member"

# Update trustee_role while preserving structure
if "spec" in yaml_data and "common" in yaml_data["spec"]:
    yaml_data["spec"]["common"]["trustee_role"] = new_trustee_role
    print(f"- Updated trustee_role to: {new_trustee_role}")

# Update image tags
if "spec" in yaml_data and "images" in yaml_data["spec"]:
    for key in yaml_data["spec"]["images"]:
        if key == "openshift_cli":
          continue
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



update_keystone_endpoints()
print("Calling rabbit params method")
with open(yaml_file, "w") as file:
    yaml_parser.dump(yaml_data, file)

print("YAML file tvo-operator-inputs.yaml is updated successfully.")
