{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

{{- define "helm-toolkit.snippets.keystone_secret_os_cloud" }}
{{- $userClass := index . 0 -}}
{{- $identityEndpoint := index . 1 -}}
{{- $context := index . 2 -}}
{{- $userContext := index $context.Values.endpoints.identity.auth $userClass }}
auth:
  auth_url: {{ tuple "identity" $identityEndpoint "api" $context | include "helm-toolkit.endpoints.keystone_endpoint_uri_lookup" }}
  username: {{ $userContext.username }}
  project_name: {{ $userContext.project_name }}
  project_domain_name: {{ $userContext.project_domain_name }}
  user_domain_name: {{ $userContext.user_domain_name }}
region_name: {{ $userContext.region_name }}
identity_api_version: 3
{{- end }}
