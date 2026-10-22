{{- define "triliovault.oslo_messaging_rabbit_queues" -}}
{{- $conf := index . 0 -}}
{{- $triliovault := index . 1 -}}
{{- $oslo := $conf.oslo_messaging_rabbit | default dict -}}
{{- range $key := list "rabbit_quorum_queue" "rabbit_transient_quorum_queue" "amqp_durable_queues" -}}
{{- if not (hasKey $oslo $key) -}}
{{- $_ := set $oslo $key (index $triliovault $key | default false) -}}
{{- end -}}
{{- end -}}
{{- if and (eq (lower (toString (index $oslo "rabbit_quorum_queue"))) "true") (not (hasKey $oslo "rabbit_ha_queues")) -}}
{{- $_ := set $oslo "rabbit_ha_queues" false -}}
{{- end -}}
{{- $_ := set $conf "oslo_messaging_rabbit" $oslo -}}
{{- end -}}

{{- define "triliovault.dms_server_queues" -}}
{{- $server := index . 0 -}}
{{- $triliovault := index . 1 -}}
{{- if not (hasKey $server "rabbitmq_queue_type") -}}
{{- $_ := set $server "rabbitmq_queue_type" (ternary "quorum" "classic" (eq (lower (toString $triliovault.rabbit_quorum_queue)) "true")) -}}
{{- end -}}
{{- if not (hasKey $server "rabbitmq_queue_durable") -}}
{{- $_ := set $server "rabbitmq_queue_durable" (ternary "true" "false" (eq (lower (toString $triliovault.amqp_durable_queues)) "true")) -}}
{{- end -}}
{{- end -}}
