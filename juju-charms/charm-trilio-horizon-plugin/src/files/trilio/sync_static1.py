import settings
import os
import subprocess
root = settings.STATIC_ROOT+os.sep+"dashboards"
subprocess.call("rm -rf  "+root)
