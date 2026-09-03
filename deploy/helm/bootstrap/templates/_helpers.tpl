{{- define "bootstrap.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: bootstrap
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: general-sim
app.kubernetes.io/component: bootstrap
{{- end }}

{{/*
Construct the Postgres DSN from individual values (falls back to global.postgres).
*/}}
{{- define "bootstrap.postgresDSN" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $host := coalesce .Values.postgres.host $globalPg.host "postgres" -}}
{{- $port := coalesce .Values.postgres.port $globalPg.port 5432 -}}
{{- $user := coalesce .Values.postgres.user $globalPg.user $globalPg.username "sim" -}}
{{- $password := required "postgres.password or global.postgres.password is required" (coalesce .Values.postgres.password $globalPg.password "") -}}
{{- $database := coalesce .Values.postgres.database $globalPg.database "sim" -}}
postgresql://{{ $user }}:{{ $password }}@{{ $host }}:{{ $port }}/{{ $database }}
{{- end }}

{{/*
Neo4j connection fields (falls back to global.neo4j).
*/}}
{{- define "bootstrap.neo4jHost" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- coalesce .Values.neo4j.host $globalNeo4j.host "neo4j" -}}
{{- end }}

{{- define "bootstrap.neo4jPort" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- coalesce .Values.neo4j.port $globalNeo4j.port 7687 -}}
{{- end }}

{{- define "bootstrap.neo4jUser" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- coalesce .Values.neo4j.user $globalNeo4j.user "neo4j" -}}
{{- end }}

{{- define "bootstrap.neo4jPassword" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- required "neo4j.password or global.neo4j.password is required" (coalesce .Values.neo4j.password $globalNeo4j.password "") -}}
{{- end }}

{{- define "bootstrap.postgresHost" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- coalesce .Values.postgres.host $globalPg.host "postgres" -}}
{{- end }}

{{- define "bootstrap.postgresPort" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- coalesce .Values.postgres.port $globalPg.port 5432 -}}
{{- end }}

{{/*
Resolve the bootstrap container image.
*/}}
{{- define "bootstrap.containerImage" -}}
{{- if .Values.image -}}
{{- .Values.image -}}
{{- else -}}
{{- $global := .Values.global | default dict -}}
{{- $registry := $global.registry | default "quay.io/rh-ai-quickstart" -}}
{{- $tag := $global.imageTag | default "latest" -}}
{{- $images := $global.images | default dict -}}
{{- $name := .Values.imageName | default ($images.app | default "general-sim-api") -}}
{{- printf "%s/%s:%s" $registry $name $tag -}}
{{- end -}}
{{- end -}}
