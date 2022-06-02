import settings
import os
import subprocess
from distutils.spawn import find_executable
root = settings.STATIC_ROOT+os.sep+"dashboards"
subprocess.call([find_executable("rm"), '-rf', root])
