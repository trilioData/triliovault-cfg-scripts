import settings
import os
import subprocess
root = settings.openstack_dashboard.settings.STATIC_ROOT+os.sep+"dashboards"
subprocess.call("rm -rf  "+root, shell=True)
