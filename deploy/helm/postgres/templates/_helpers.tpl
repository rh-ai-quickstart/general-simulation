{{/*
Resolve the Postgres container image.

Uses .Values.image when set (full ref); otherwise composes from global.registry,
global.images.postgres (or imageName), and global.imageTag.
*/}}
{{- define "postgres.containerImage" -}}
{{- if .Values.image -}}
{{- .Values.image -}}
{{- else -}}
{{- $global := .Values.global | default dict -}}
{{- $registry := $global.registry | default "quay.io/rh-ai-quickstart" -}}
{{- $tag := $global.imageTag | default "latest" -}}
{{- $images := $global.images | default dict -}}
{{- $name := .Values.imageName | default ($images.postgres | default "general-sim-postgres") -}}
{{- printf "%s/%s:%s" $registry $name $tag -}}
{{- end -}}
{{- end -}}

{{/*
Postgres credentials (falls back to global.postgres).
*/}}
{{- define "postgres.username" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- coalesce .Values.postgres.username $globalPg.user $globalPg.username "sim" -}}
{{- end }}

{{- define "postgres.password" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- required "postgres.password or global.postgres.password is required — pass via --set postgres.password=<pw> or global.postgres.password" (coalesce .Values.postgres.password $globalPg.password "") -}}
{{- end }}

{{- define "postgres.database" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- coalesce .Values.postgres.database $globalPg.database "sim" -}}
{{- end }}
{{- define "postgres.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: postgres
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: general-sim
app.kubernetes.io/component: postgres
{{- end }}

{{/*
Selector labels (used in matchLabels and Service selectors)
*/}}
{{- define "postgres.selectorLabels" -}}
app.kubernetes.io/name: postgres
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
