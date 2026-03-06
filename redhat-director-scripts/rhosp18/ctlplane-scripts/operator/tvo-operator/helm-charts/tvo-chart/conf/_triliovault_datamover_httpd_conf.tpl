<VirtualHost *:8784>
  ServerName triliovault-datamover-internal.trilio-openstack.svc

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
  ProxyPass / http://127.0.0.1:8783/ connectiontimeout=600 timeout=600
  ProxyPassReverse / http://127.0.0.1:8783/


  Timeout 600
</VirtualHost>

# Public vhost configuration for https://triliovault-datamover-public-trilio-openstack.apps.trilio.trilio.demo:8781/v1/s
<VirtualHost *:8784>
  ServerName {{ .Values.keystone.datamover_api.public_auth_host }}

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
  ProxyPass / http://127.0.0.1:8783/ connectiontimeout=600 timeout=600
  ProxyPassReverse / http://127.0.0.1:8783/


  Timeout 600
</VirtualHost>
