import settings
import subprocess
ls = settings.INSTALLED_APPS

data = ""
for app in ls:
    if app != 'dashboards':
        data += "-i "+str(app)+" "

subprocess.call("{{PYTHON_VERSION}} {{MANAGE_FILE}} collectstatic --noinput "+data)

