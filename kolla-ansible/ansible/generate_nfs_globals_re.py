import yaml
import sys
from yaml.loader import SafeLoader


def get_node_list(node_list):
## Example: node_list = "compute[01:10].trilio.demo"
  sub_strings = node_list.split(':')
  sub_strings_left = sub_strings[0].split('[')
  sub_strings_right = sub_strings[1].split(']')

  if (len(sub_strings_right) == 1):
    domain_name_exists = False
  else:
    domain_name_exists = True
    node_domain_name = sub_strings_right[1]

  stop_index = int(sub_strings_right[0])
  start_index = int(sub_strings_left[1])
  node_short_name = sub_strings_left[0]
  index = int(start_index)
  expanded_node_list = []

  while(index <= stop_index):
    if domain_name_exists:
      expanded_node_list.append(node_short_name+str(index)+node_domain_name)
    else:
      expanded_node_list.append(node_short_name+str(index))
    index +=1
  return expanded_node_list



total_arguments = len(sys.argv)

if total_arguments < 2:
   print ("This script takes exactly one command line argument.")
   print ("python ./generate_nfs_globals.py <NFS_SHARE_NAME>")
   print ("Example:")
   print ("    python ./generate_nfs_globals.py /var/nfs_share")
   exit(1)

nfs_share_name = sys.argv[1]

input_file_name='triliovault_nfs_mapping.yml'
input_stream = open(input_file_name, 'r')
input_data = yaml.load(input_stream, Loader=yaml.FullLoader)

output_file_name= 'nfs_globals.yml'
output_data = {}
output_data['triliovault_nfs_mapping'] = {}
for nfs_ip in input_data['triliovault_nfs_mapping']:
    for compute_host_name in input_data['triliovault_nfs_mapping'][nfs_ip]:
        nfs_share_full_path = nfs_ip+":"+nfs_share_name
        if '[' in compute_host_name:
          expanded_node_list = get_node_list(compute_host_name)
          for node in expanded_node_list:
              output_data['triliovault_nfs_mapping'][node] = nfs_share_full_path
        else:
          output_data['triliovault_nfs_mapping'][compute_host_name] = nfs_share_full_path



with open(output_file_name, 'w') as output_data_stream:
    data = yaml.dump(output_data, output_data_stream, sort_keys=False)

print ("\nA new file is generated in current directory, named 'nfs_globals.yml'")
print ("\nPlease open that file and validate that all compute nodes of your cloud are mentioned there")
print ("\nYou need to append this file content to triliovault_globals.yml\n")
