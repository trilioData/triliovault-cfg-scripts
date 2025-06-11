Listen 8781
<VirtualHost *:8781>
  ServerName triliovault-wlm-internal.trilio-openstack.svc

  ## Logging
  ErrorLog /dev/stdout
  ServerSignature Off
  CustomLog /dev/stdout combined
  SetEnvIf X-Forwarded-Proto https HTTPS=1

  ## SSL directives
  SSLEngine on
  SSLCertificateFile      "/etc/pki/tls/certs/internal.crt"
  SSLCertificateKeyFile   "/etc/pki/tls/private/internal.key"

  ## Proxy Configuration
  ProxyPreserveHost On
  ProxyTimeout 600
  ProxyPass / http://127.0.0.1:8780/ connectiontimeout=600 timeout=600
  ProxyPassReverse / http://127.0.0.1:8780/


  Timeout 600
</VirtualHost>

# Public vhost configuration for https://triliovault-wlm-public-trilio-openstack.apps.trilio.trilio.bos2:8781/v1/s
<VirtualHost *:8781>
  ServerName {{ .Values.keystone.wlm_api.public_auth_host }}

  ## Logging
  ErrorLog /dev/stdout
  ServerSignature Off
  CustomLog /dev/stdout combined
  SetEnvIf X-Forwarded-Proto https HTTPS=1

  ## SSL directives
  SSLEngine on
  SSLCertificateFile      "/etc/pki/tls/certs/public.crt"
  SSLCertificateKeyFile   "/etc/pki/tls/private/public.key"

  ## Proxy Configuration
  ProxyPreserveHost On
  ProxyTimeout 600
  ProxyPass / http://127.0.0.1:8780/ connectiontimeout=600 timeout=600
  ProxyPassReverse / http://127.0.0.1:8780/


  Timeout 600
</VirtualHost>
