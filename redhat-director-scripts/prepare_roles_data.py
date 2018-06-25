import yaml, sys
import os

role_data_file = sys.argv[1]

with open(role_data_file) as f:
    roles = yaml.load(f)

for role in roles:
    if role["name"] == "Controller":
        controller_service_list = role['ServicesDefault']
        if 'OS::TripleO::Services::TrilioDatamoverApi' not in controller_service_list:
            controller_service_list.append('OS::TripleO::Services::TrilioDatamoverApi')
        if 'OS::TripleO::Services::TrilioHorizonPlugin' not in controller_service_list:
            controller_service_list.append('OS::TripleO::Services::TrilioHorizonPlugin')
	role['ServicesDefault'] = controller_service_list 
    if role["name"] == "Compute": 
	compute_service_list = role['ServicesDefault']
        if 'OS::TripleO::Services::TrilioDatamover' not in compute_service_list:
            compute_service_list.append('OS::TripleO::Services::TrilioDatamover')
        role['ServicesDefault'] = compute_service_list

new_roles_data_file = os.path.dirname(os.path.realpath(__file__)) + "/roles_data.yaml"
with open(new_roles_data_file, "w") as f:
    yaml.dump(roles, f)

print ("\nNew roles data file is created at: %s\nTo install trilio components on overcloud, you need to use this new roles data file\n" % new_roles_data_file)
