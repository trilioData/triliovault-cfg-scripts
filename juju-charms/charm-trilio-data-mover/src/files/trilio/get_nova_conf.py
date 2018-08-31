from oslo_config import cfg
from nova import config as nova_conf
CONF = cfg.CONF
nova_conf.parse_args(["/usr/bin/nova-compute"])
config_files = " --config-file=".join([""] + CONF['config_file']).strip()
print(config_files)
