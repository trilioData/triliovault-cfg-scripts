import os
import sys
file_name = sys.argv[1]
pids = [pid for pid in os.listdir('/proc') if pid.isdigit()]
config_files = list()
for pid in pids:
    try:
        for ps in open(os.path.join('/proc', pid, 'cmdline'), 'rb'):
            if True in [b'nova-compute' in s for s in ps.split(b'\0')]:
                fields = ps.split(b'\0')
                for index, value in enumerate(fields):
                    if value == '--config-file':
                        config_files.append(value + '=' + fields[index + 1])
                    elif value.startswith(b'--config-file='):
                        config_files.append(value)
    except IOError: # proc has already terminated
        continue
if not config_files:
    config_files = '--config-file=' + file_name
else:
    config_files = ' '.join(list(set(config_files)))

print('{}'.format(config_files))