"""
Takes encoded compact format mapping of nfs shares and compute nodes

Returns expanded one to one mapping of compute nodes and nfs shares

Input file name is: triliovault_nfs_map_input.yml

Output file name: triliovault_nfs_map_output.yml

"""


import yaml

# This function takes compact a compute node name string and returns
#
# expanded list of all eligible host names
# Example: compact node name can be - "compute[1:3]"
# Expanded list will be: ['compute1', 'compute2', 'compute3']


def get_node_list(node_list):
    """ Decode node name in range format and Return all eligible node names as a list."""
    sub_strings = node_list.split(':')
    sub_strings_left = sub_strings[0].split('[')
    sub_strings_right = sub_strings[1].split(']')

    if len(sub_strings_right) == 1:
        domain_name_exists = False
    else:
        domain_name_exists = True
        node_domain_name = sub_strings_right[1]

    stop_index = int(sub_strings_right[0])
    start_index = int(sub_strings_left[1])
    node_short_name = sub_strings_left[0]
    index = int(start_index)
    expanded_node_list = []

    while index <= stop_index:
        if domain_name_exists:
            expanded_node_list.append(
                node_short_name + str(index) + node_domain_name)
        else:
            expanded_node_list.append(node_short_name + str(index))
        index += 1
    return expanded_node_list


def create_compute_nfs_map():
    """

    Process coded compute hostname and share mapping

    and return expanded one to one mapping of compute node

    host names and nfs shares

    """

    with open(INPUT_FILE_NAME, 'r') as input_stream:
        input_data = yaml.load(input_stream, Loader=yaml.FullLoader)

    output_data = {}
    output_data['triliovault_nfs_map'] = {}

    # For multi-ip nfs shares map, first map only.
    # Discovers all compute node names and assignes first nfs share. Creates a
    # dictionary.
    if input_data['multi_ip_nfs_shares']:
        nfs_share_map = input_data['multi_ip_nfs_shares'][0]
    else:
        nfs_share_map = []
    for nfs_share in nfs_share_map:
        for compute_host_name in nfs_share_map[nfs_share]:
            #nfs_share_full_path = nfs_ip+":"+nfs_share_name
            if '[' in compute_host_name:
                expanded_compute_host_list = get_node_list(compute_host_name)
                for node in expanded_compute_host_list:
                    output_data['triliovault_nfs_map'][node] = nfs_share
            else:
                output_data['triliovault_nfs_map'][compute_host_name] = nfs_share


    # For multi ip nfs share maps starting from second map
    for nfs_share_map in input_data['multi_ip_nfs_shares'][1:]:
        for nfs_share in nfs_share_map:
            for compute_host_name in nfs_share_map[nfs_share]:
                #nfs_share_full_path = nfs_ip+":"+nfs_share_name
                if '[' in compute_host_name:
                    expanded_compute_host_list = get_node_list(compute_host_name)
                    for node in expanded_compute_host_list:
                        output_data['triliovault_nfs_map'][node] = output_data['triliovault_nfs_map'][node] + ',' + nfs_share
                else:
                    output_data['triliovault_nfs_map'][compute_host_name] = output_data['triliovault_nfs_map'][compute_host_name] + ',' + nfs_share

    # Append all single ip nfs shares separated by comma delimater and create
    # a single string
    single_ip_nfs_shares_string = ""
    for single_ip_nfs_share in input_data['single_ip_nfs_shares']:
        single_ip_nfs_shares_string = single_ip_nfs_shares_string + ',' + single_ip_nfs_share


    # append above single ip nfs share string against all compute nodes in
    # output dictionary
    if single_ip_nfs_shares_string:
        for compute_host, nfs_share in output_data['triliovault_nfs_map'].items():
            output_data['triliovault_nfs_map'][compute_host] = nfs_share + single_ip_nfs_shares_string

    # Write output dictionary to a yaml file
    with open(OUTPUT_FILE_NAME, 'w') as output_data_stream:
        yaml.dump(output_data, output_data_stream, sort_keys=False, indent=4)


def main():
    global INPUT_FILE_NAME
    INPUT_FILE_NAME = 'triliovault_nfs_map_input.yml'
    global OUTPUT_FILE_NAME
    OUTPUT_FILE_NAME = 'triliovault_nfs_map_output.yml'
    create_compute_nfs_map()
    print("\n Expanded mapping of compute nodes and nfs shares is written in file "+ OUTPUT_FILE_NAME + "\n")


if __name__=="__main__":
    main()