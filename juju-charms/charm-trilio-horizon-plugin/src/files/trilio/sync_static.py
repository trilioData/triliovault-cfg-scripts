import settings
import subprocess
ls = settings.INSTALLED_APPS
data = ""
for app in ls:
    if app != 'dashboards':
        data += "-i "+str(app)+" "

subprocess.call(
    "/usr/share/openstack-dashboard/manage.py collectstatic --noinput "+data,
    shell=True)
