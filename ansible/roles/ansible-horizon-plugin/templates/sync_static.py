import settings
ls = settings.INSTALLED_APPS

data = ""
for app in ls:
    if app != 'dashboards':
        data += "-i "+str(app)+" "

print(data)

