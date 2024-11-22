Listen 8781
<VirtualHost *:8781>
  ServerName triliovault-wlm-internal.triliovault.svc

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
  ProxyPass / http://127.0.0.1:8780/
  ProxyPassReverse / http://127.0.0.1:8780/


  Timeout 60
</VirtualHost>

# Public vhost configuration for https://triliovault-wlm-public-triliovault.apps.trilio.trilio.bos2:8781/v1/s
<VirtualHost *:8781>
  ServerName triliovault-wlm-public-triliovault.apps.trilio.trilio.bos2

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
  ProxyPass / http://127.0.0.1:8780/
  ProxyPassReverse / http://127.0.0.1:8780/


  Timeout 60
</VirtualHost>