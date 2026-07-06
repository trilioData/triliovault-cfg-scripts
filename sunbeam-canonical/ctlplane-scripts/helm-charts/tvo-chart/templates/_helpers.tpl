{{/*
Common labels
*/}}
{{- define "tvo.labels" -}}
app.kubernetes.io/name: triliovault
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Image pull secrets — referenced by all Deployment and Job pod specs.
The trilio-registry-secret is created by secret-registry-auth.yaml
only when trilio_container_registry_login_enabled is true.
*/}}
{{- define "tvo.imagePullSecrets" -}}
{{- if .Values.images.trilio_container_registry_login_enabled }}
imagePullSecrets:
  - name: trilio-registry-secret
{{- end }}
{{- end }}

{{/*
CA bundle volume — only rendered when tls.ca_bundle_configmap is set.
Mount path: /etc/ssl/certs/sunbeam-ca.crt (ca.crt key from the ConfigMap).
*/}}
{{- define "tvo.caBundleVolume" -}}
{{- if .Values.tls.ca_bundle_configmap }}
- name: ca-bundle
  configMap:
    name: {{ .Values.tls.ca_bundle_configmap }}
{{- end }}
{{- end }}

{{- define "tvo.caBundleVolumeMount" -}}
{{- if .Values.tls.ca_bundle_configmap }}
- name: ca-bundle
  mountPath: /etc/ssl/certs/sunbeam-ca.crt
  subPath: ca.crt
  readOnly: true
{{- end }}
{{- end }}

{{- define "tvo.caBundleEnv" -}}
{{- if .Values.tls.ca_bundle_configmap }}
- name: OS_CACERT
  value: /etc/ssl/certs/sunbeam-ca.crt
- name: REQUESTS_CA_BUNDLE
  value: /etc/ssl/certs/sunbeam-ca.crt
{{- end }}
{{- end }}
