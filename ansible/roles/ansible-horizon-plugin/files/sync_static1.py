import settings
import os
import subprocess
import shutil
root = settings.STATIC_ROOT+os.sep+"dashboards"
subprocess.call([shutil.which("rm"), '-rf', root])
