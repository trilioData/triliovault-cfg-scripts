def get_node_list (node_list):
## Example: node_list = "compute[01:10].trilio.demo"

  sub_strings = node_list.split(':')
  sub_strings_left = sub_strings[0].split('[')
  sub_strings_right = sub_strings[1].split(']')

  if (len(sub_strings_right) == 1):
    domain_name_exists = False
  else
    domain_name_exists = True
    node_domain_name = sub_strings_right[1]

  sub_strings_right[0] = 10,  sub_strings_right[1] = ".trilio.demo"
  stop_index = sub_strings_right[0]
  start_index = sub_strings_left[1]
  node_short_name = sub_strings_left[0]
  index = start_index
  expanded_node_list = []

  while(index >= stop_index):
    if domain_name_exists:
      expanded_node_list.add(node_short_name+index+node_domain_name)
    else:
      expanded_node_list.add(node_short_name+index)
	  
    return expanded_node_list