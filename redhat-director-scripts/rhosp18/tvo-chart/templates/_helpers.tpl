{{- define "to_ini" -}}
{{- range $section, $pairs := . -}}
[{{ $section }}]
{{- range $key, $value := $pairs }}
{{ $key }} = {{ $value }}
{{- end }}
{{ end -}}
{{- end -}}