import yaml

role_data_file = '/tmp/roles_data.yaml'

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
		 
with open(role_data_file, "w") as f:
    yaml.dump(roles, f)
