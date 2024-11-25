<VirtualHost *:8784>
  ServerName triliovault-datamover-internal.triliovault.svc

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
  ProxyPass / http://127.0.0.1:8783/
  ProxyPassReverse / http://127.0.0.1:8783/


  Timeout 60
</VirtualHost>

# Public vhost configuration for https://triliovault-datamover-public-triliovault.apps.trilio.trilio.bos2:8781/v1/s
<VirtualHost *:8784>
  ServerName triliovault-datamover-public-triliovault.apps.trilio.trilio.bos2

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
  ProxyPass / http://127.0.0.1:8783/
  ProxyPassReverse / http://127.0.0.1:8783/


  Timeout 60
</VirtualHost>