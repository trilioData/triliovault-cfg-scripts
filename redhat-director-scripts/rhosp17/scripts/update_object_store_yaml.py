#!/usr/bin/python
import yaml
import os
import pdb
from ruamel.yaml.comments import CommentedMap
from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import PreservedScalarString


# Function to read YAML files
def read_yaml_file(file_path):
    yaml = YAML()
    with open(file_path, 'r') as file:
        return yaml.load(file)

# Function to write to YAML files
def write_yaml_file(file_path, data):
    yaml = YAML()
    yaml.indent(mapping=2, sequence=4, offset=2)
    with open(file_path, 'w') as file:
        yaml.dump(data, file)

'''

# Function to read YAML files
def read_yaml_file(file_path):
    with open(file_path, 'r') as file:
        return yaml.safe_load(file)

# Function to write to YAML files
def write_yaml_file(file_path, data):
    with open(file_path, 'w') as file:
        yaml.dump(data, file)

'''
# Define the paths to the YAML files
script_dir = os.path.dirname(__file__)
services_dir = os.path.join(script_dir, '../services')
env_dir = os.path.join(script_dir, '../environments')
trilio_env_yaml_path = os.path.join(env_dir, 'trilio_env.yaml')
triliovault_object_store_yaml_path = os.path.join(services_dir, 'triliovault-object-store.yaml')

# Read the TrilioBackupTargets from trilio_env.yaml
trilio_env = read_yaml_file(trilio_env_yaml_path)
trilio_backup_targets = trilio_env.get('parameter_defaults', {}).get('TrilioBackupTargets', [])


# Filter S3 backup targets
s3_backup_targets = [target for target in trilio_backup_targets if target.get('backup_target_type') == 's3']

# If there are no S3 backup targets, exit
if not s3_backup_targets:
    print("No S3 backup targets found.")
    exit(0)

# Read the triliovault-object-store.yaml file
triliovault_object_store = read_yaml_file(triliovault_object_store_yaml_path)

# Ensure the necessary sections exist
triliovault_object_store['outputs']['role_data']['value']['kolla_config'] = {}
triliovault_object_store['outputs']['role_data']['value']['docker_config']['step_5'] = {}



# Update the kolla_config section for each S3 backup target
for target in s3_backup_targets:
    backup_target_name = target.get('backup_target_name')
    kolla_config = {
        f"/var/lib/kolla/config_files/triliovault_object_store_{backup_target_name}.json": {
            "command": f"/usr/bin/python3 /usr/bin/s3vaultfuse.py --config-file=/etc/triliovault-object-store/triliovault-object-store-{backup_target_name}.conf",
            "config_files": [
                {
                    "source": "/var/lib/kolla/config_files/triliovaultobjectstore/*",
                    "dest": "/",
                    "merge": True,
                    "preserve_properties": True
                }
            ],
            "permissions": [
                {
                    "path": "/var/log/triliovault/",
                    "owner": "nova:nova",
                    "recurse": True
                }
            ]
        }
    }
    
    triliovault_object_store['outputs']['role_data']['value']['kolla_config'].update(kolla_config)
    #kolla_config.update(s3_config)

    docker_config_step5 = CommentedMap({
        f"triliovault_object_store_{backup_target_name}": {
            "image": CommentedMap([("get_param", "ContainerTriliovaultWlmImage")]),
            "net": "host",
            "privileged": True,
            "user": "nova",
            "restart": "always",
            "volumes": {
                    "list_concat": [
                        CommentedMap([("get_attr", ["ContainersCommon", "volumes"])]),
                        [
                            f"/var/lib/kolla/config_files/triliovault_object_store_{backup_target_name}.json:/var/lib/kolla/config_files/config.json:ro",
                            "/var/lib/config-data/puppet-generated/triliovaultobjectstore/:/var/lib/kolla/config_files/triliovaultobjectstore:ro",
                            "/var/log/containers/triliovault-object-store:/var/log/triliovault:z",
                            "/dev:/dev",
                            "/lib/modules:/lib/modules"
                        ]
                    ]
                },
            "environment": {
                "KOLLA_CONFIG_STRATEGY": "COPY_ALWAYS"
            }
        }
    })
   
    triliovault_object_store['outputs']['role_data']['value']['docker_config']['step_5'].update(docker_config_step5)

# Write the updated triliovault-object-store.yaml file
write_yaml_file(triliovault_object_store_yaml_path, triliovault_object_store)

print("triliovault-object-store.yaml has been updated successfully.")
