{{- define "ingestion.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: general-sim-ingestion
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: general-sim
app.kubernetes.io/component: ingestion
{{- end }}

{{- define "ingestion.selectorLabels" -}}
app.kubernetes.io/name: general-sim-ingestion
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "ingestion.postgresDSN" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $host := coalesce .Values.postgres.host $globalPg.host "postgres" -}}
{{- $port := coalesce .Values.postgres.port $globalPg.port 5432 -}}
{{- $user := coalesce .Values.postgres.user $globalPg.user $globalPg.username "sim" -}}
{{- $password := required "postgres.password or global.postgres.password is required" (coalesce .Values.postgres.password $globalPg.password "") -}}
{{- $database := coalesce .Values.postgres.database $globalPg.database "sim" -}}
postgresql://{{ $user }}:{{ $password }}@{{ $host }}:{{ $port }}/{{ $database }}
{{- end }}

{{- define "ingestion.neo4jURI" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $host := coalesce .Values.neo4j.host $globalNeo4j.host "neo4j" -}}
{{- $port := coalesce .Values.neo4j.port $globalNeo4j.port 7687 -}}
bolt://{{ $host }}:{{ $port }}
{{- end }}

{{- define "ingestion.neo4jUser" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- coalesce .Values.neo4j.user $globalNeo4j.user "neo4j" -}}
{{- end }}

{{- define "ingestion.neo4jPassword" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- required "neo4j.password or global.neo4j.password is required" (coalesce .Values.neo4j.password $globalNeo4j.password "") -}}
{{- end }}

{{- define "ingestion.postgresHost" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- coalesce .Values.postgres.host $globalPg.host "postgres" -}}
{{- end }}

{{- define "ingestion.postgresPort" -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- coalesce .Values.postgres.port $globalPg.port 5432 -}}
{{- end }}

{{- define "ingestion.neo4jHost" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- coalesce .Values.neo4j.host $globalNeo4j.host "neo4j" -}}
{{- end }}

{{- define "ingestion.neo4jPort" -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- coalesce .Values.neo4j.port $globalNeo4j.port 7687 -}}
{{- end }}

{{/*
Shared ingestion container spec (CronJob + run-on-deploy hook Job).
*/}}
{{- define "ingestion.container" -}}
- name: ingestion
  image: {{ include "ingestion.containerImage" . }}
  imagePullPolicy: Always
  command:
    - python
    - -m
    - src.ingestion
    - --adapter
    - {{ .Values.adapterId | quote }}
  env:
    - name: POSTGRES_DSN
      value: {{ include "ingestion.postgresDSN" . | quote }}
    - name: NEO4J_URI
      value: {{ include "ingestion.neo4jURI" . | quote }}
    - name: NEO4J_USER
      value: {{ include "ingestion.neo4jUser" . | quote }}
    - name: NEO4J_PASSWORD
      value: {{ include "ingestion.neo4jPassword" . | quote }}
    - name: LLM_BASE_URL
      value: {{ .Values.llm.baseUrl | quote }}
    - name: LLM_BACKEND
      value: {{ .Values.llm.backend | quote }}
    - name: OPENAI_API_KEY
      value: {{ .Values.llm.apiKey | quote }}
    - name: GENERATION_MODEL_ID
      value: {{ .Values.models.generation | quote }}
    - name: EMBEDDING_MODEL_ID
      value: {{ .Values.models.embedding | quote }}
    - name: EMBEDDING_DIMENSION
      value: {{ .Values.models.embeddingDimension | quote }}
    - name: ENABLED_DOMAINS
      value: {{ .Values.enabledDomains | quote }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  volumeMounts:
    - name: tmp
      mountPath: /tmp
{{- end }}

{{/*
Resolve the ingestion container image.
*/}}
{{- define "ingestion.containerImage" -}}
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
