import settings
import subprocess
ls = settings.openstack_dashboard.settings.INSTALLED_APPS
data = ""
for app in ls:
    if app != 'dashboards':
       data += "-i "+str(app)+" "
subprocess.call("./manage.py collectstatic --noinput "+data)
