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
