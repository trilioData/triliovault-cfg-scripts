import sys
from yaml.loader import SafeLoader

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
        output_data['triliovault_nfs_mapping'][compute_host_name] = nfs_share_full_path



with open(output_file_name, 'w') as output_data_stream:
    data = yaml.dump(output_data, output_data_stream)

print ("\nA new file is generated in current directory, named 'nfs_globals.yml'")
print ("\nPlease open that file and validate that all compute nodes of your cloud are mentioned there")
print ("\nYou need to append this file content to '/etc/kolla/globals.yml'\n"