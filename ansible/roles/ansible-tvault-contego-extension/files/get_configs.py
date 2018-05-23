from oslo_config import cfg
from nova import config
CONF = cfg.CONF
config.parse_args(["/usr/bin/nova-compute"])
config_files = " --config-file=".join([""] + CONF['config_file']).strip()
print config_files
