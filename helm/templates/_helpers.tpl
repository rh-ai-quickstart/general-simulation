{{/*
Shared and component helpers for the general-simulation chart.
Component templates read scoped values: .Values.postgres, .Values.api, etc.
*/}}

{{/* ── Postgres ─────────────────────────────────────────────────────────── */}}

{{- define "postgres.containerImage" -}}
{{- $v := .Values.postgres -}}
{{- if $v.image -}}
{{- $v.image -}}
{{- else -}}
{{- $global := .Values.global | default dict -}}
{{- $registry := $global.registry | default "quay.io/rh-ai-quickstart" -}}
{{- $tag := $global.imageTag | default "latest" -}}
{{- $images := $global.images | default dict -}}
{{- $name := $v.imageName | default ($images.postgres | default "general-sim-postgres") -}}
{{- printf "%s/%s:%s" $registry $name $tag -}}
{{- end -}}
{{- end -}}

{{- define "postgres.username" -}}
{{- $v := .Values.postgres -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.username $globalPg.user $globalPg.username "sim" -}}
{{- end }}

{{- define "postgres.password" -}}
{{- $v := .Values.postgres -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- required "postgres.postgres.password or global.postgres.password is required" (coalesce $pg.password $globalPg.password "") -}}
{{- end }}

{{- define "postgres.database" -}}
{{- $v := .Values.postgres -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.database $globalPg.database "sim" -}}
{{- end }}

{{- define "postgres.storageSize" -}}
{{- $storage := (.Values.postgres.storage | default dict) -}}
{{- $storage.size | default "10Gi" -}}
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

{{- define "postgres.selectorLabels" -}}
app.kubernetes.io/name: postgres
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ── API ──────────────────────────────────────────────────────────────── */}}

{{- define "api.replicas" -}}
{{- .Values.api.replicas | default 1 -}}
{{- end }}

{{- define "api.routeEnabled" -}}
{{- $route := (.Values.api.route | default dict) -}}
{{- if kindIs "bool" $route.enabled }}{{ $route.enabled }}{{ else }}true{{ end -}}
{{- end }}

{{- define "api.waitForEnabled" -}}
{{- $waitFor := (.Values.api.waitFor | default dict) -}}
{{- if kindIs "bool" $waitFor.enabled }}{{ $waitFor.enabled }}{{ else }}true{{ end -}}
{{- end }}

{{- define "api.waitForTimeoutSeconds" -}}
{{- $waitFor := (.Values.api.waitFor | default dict) -}}
{{- $waitFor.timeoutSeconds | default 300 -}}
{{- end }}

{{- define "api.neo4jUser" -}}
{{- $neo4j := (.Values.api.neo4j | default dict) -}}
{{- $neo4j.user | default "neo4j" -}}
{{- end }}

{{- define "api.llmBaseUrl" -}}
{{- $llm := (.Values.api.llm | default dict) -}}
{{- $llm.baseUrl | default "http://llamastack:8321/v1" -}}
{{- end }}

{{- define "api.llmBackend" -}}
{{- $llm := (.Values.api.llm | default dict) -}}
{{- $llm.backend | default "openai" -}}
{{- end }}

{{- define "api.llmApiKey" -}}
{{- $llm := (.Values.api.llm | default dict) -}}
{{- $llm.apiKey | default "unused" -}}
{{- end }}

{{- define "api.generationModelId" -}}
{{- required "api.models.generation is required" ((.Values.api.models | default dict).generation) -}}
{{- end }}

{{- define "api.embeddingModelId" -}}
{{- $models := (.Values.api.models | default dict) -}}
{{- $models.embedding | default "sentence-transformers/nomic-ai/nomic-embed-text-v1.5" -}}
{{- end }}

{{- define "api.embeddingDimension" -}}
{{- $models := (.Values.api.models | default dict) -}}
{{- $models.embeddingDimension | default "768" -}}
{{- end }}

{{- define "api.enabledDomains" -}}
{{- .Values.api.enabledDomains | default "aviation,shipping" -}}
{{- end }}

{{- define "api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: general-sim-api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: general-sim
app.kubernetes.io/component: api
{{- end }}

{{- define "api.selectorLabels" -}}
app.kubernetes.io/name: general-sim-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "api.postgresDSN" -}}
{{- $v := .Values.api -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- $host := coalesce $pg.host $globalPg.host "postgres" -}}
{{- $port := coalesce $pg.port $globalPg.port 5432 -}}
{{- $user := coalesce $pg.user $pg.username $globalPg.user $globalPg.username "sim" -}}
{{- $password := required "postgres.password or global.postgres.password is required" (coalesce $pg.password $globalPg.password "") -}}
{{- $database := coalesce $pg.database $globalPg.database "sim" -}}
postgresql://{{ $user }}:{{ $password }}@{{ $host }}:{{ $port }}/{{ $database }}
{{- end }}

{{- define "api.neo4jURI" -}}
{{- $v := .Values.api -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- $host := coalesce $nj.host $globalNeo4j.host "neo4j" -}}
{{- $port := coalesce $nj.port $globalNeo4j.port 7687 -}}
bolt://{{ $host }}:{{ $port }}
{{- end }}

{{- define "api.neo4jPassword" -}}
{{- $v := .Values.api -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- required "neo4j.password or global.neo4j.password is required" (coalesce $nj.password $globalNeo4j.password "") -}}
{{- end }}

{{- define "api.postgresHost" -}}
{{- $v := .Values.api -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.host $globalPg.host "postgres" -}}
{{- end }}

{{- define "api.postgresPort" -}}
{{- $v := .Values.api -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.port $globalPg.port 5432 -}}
{{- end }}

{{- define "api.neo4jHost" -}}
{{- $v := .Values.api -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.host $globalNeo4j.host "neo4j" -}}
{{- end }}

{{- define "api.neo4jPort" -}}
{{- $v := .Values.api -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.port $globalNeo4j.port 7687 -}}
{{- end }}

{{- define "api.containerImage" -}}
{{- $v := .Values.api -}}
{{- if $v.image -}}
{{- $v.image -}}
{{- else -}}
{{- $global := .Values.global | default dict -}}
{{- $registry := $global.registry | default "quay.io/rh-ai-quickstart" -}}
{{- $tag := $global.imageTag | default "latest" -}}
{{- $images := $global.images | default dict -}}
{{- $name := $v.imageName | default ($images.app | default "general-sim-api") -}}
{{- printf "%s/%s:%s" $registry $name $tag -}}
{{- end -}}
{{- end -}}

{{- define "api.waitForDepsInit" -}}
{{- if include "api.waitForEnabled" . | eq "true" }}
initContainers:
  - name: wait-for-deps
    image: {{ include "api.containerImage" . }}
    imagePullPolicy: Always
    command:
      - python
      - -c
      - |
        import socket, sys, time
        targets = [
            ({{ include "api.postgresHost" . | quote }}, {{ include "api.postgresPort" . }}),
            ({{ include "api.neo4jHost" . | quote }}, {{ include "api.neo4jPort" . }}),
        ]
        timeout = {{ include "api.waitForTimeoutSeconds" . }}
        deadline = time.time() + timeout
        for host, port in targets:
            print(f"Waiting for {host}:{port} (timeout={timeout}s)...", flush=True)
            while True:
                try:
                    with socket.create_connection((host, port), timeout=2):
                        print(f"{host}:{port} is up", flush=True)
                        break
                except OSError as exc:
                    if time.time() >= deadline:
                        print(f"Timed out waiting for {host}:{port}: {exc}", file=sys.stderr)
                        sys.exit(1)
                    time.sleep(2)
        print("Dependencies ready", flush=True)
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    volumeMounts:
      - name: tmp
        mountPath: /tmp
{{- end }}
{{- end }}

{{/* ── Bootstrap ────────────────────────────────────────────────────────── */}}

{{- define "bootstrap.waitForEnabled" -}}
{{- $waitFor := (.Values.bootstrap.waitFor | default dict) -}}
{{- if kindIs "bool" $waitFor.enabled }}{{ $waitFor.enabled }}{{ else }}true{{ end -}}
{{- end }}

{{- define "bootstrap.waitForTimeoutSeconds" -}}
{{- $waitFor := (.Values.bootstrap.waitFor | default dict) -}}
{{- $waitFor.timeoutSeconds | default 300 -}}
{{- end }}

{{- define "bootstrap.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: bootstrap
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: general-sim
app.kubernetes.io/component: bootstrap
{{- end }}

{{- define "bootstrap.postgresDSN" -}}
{{- $v := .Values.bootstrap -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- $host := coalesce $pg.host $globalPg.host "postgres" -}}
{{- $port := coalesce $pg.port $globalPg.port 5432 -}}
{{- $user := coalesce $pg.user $pg.username $globalPg.user $globalPg.username "sim" -}}
{{- $password := required "postgres.password or global.postgres.password is required" (coalesce $pg.password $globalPg.password "") -}}
{{- $database := coalesce $pg.database $globalPg.database "sim" -}}
postgresql://{{ $user }}:{{ $password }}@{{ $host }}:{{ $port }}/{{ $database }}
{{- end }}

{{- define "bootstrap.neo4jHost" -}}
{{- $v := .Values.bootstrap -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.host $globalNeo4j.host "neo4j" -}}
{{- end }}

{{- define "bootstrap.neo4jPort" -}}
{{- $v := .Values.bootstrap -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.port $globalNeo4j.port 7687 -}}
{{- end }}

{{- define "bootstrap.neo4jUser" -}}
{{- $v := .Values.bootstrap -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.user $globalNeo4j.user "neo4j" -}}
{{- end }}

{{- define "bootstrap.neo4jPassword" -}}
{{- $v := .Values.bootstrap -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- required "neo4j.password or global.neo4j.password is required" (coalesce $nj.password $globalNeo4j.password "") -}}
{{- end }}

{{- define "bootstrap.postgresHost" -}}
{{- $v := .Values.bootstrap -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.host $globalPg.host "postgres" -}}
{{- end }}

{{- define "bootstrap.postgresPort" -}}
{{- $v := .Values.bootstrap -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.port $globalPg.port 5432 -}}
{{- end }}

{{- define "bootstrap.containerImage" -}}
{{- $v := .Values.bootstrap -}}
{{- if $v.image -}}
{{- $v.image -}}
{{- else -}}
{{- $global := .Values.global | default dict -}}
{{- $registry := $global.registry | default "quay.io/rh-ai-quickstart" -}}
{{- $tag := $global.imageTag | default "latest" -}}
{{- $images := $global.images | default dict -}}
{{- $name := $v.imageName | default ($images.app | default "general-sim-api") -}}
{{- printf "%s/%s:%s" $registry $name $tag -}}
{{- end -}}
{{- end -}}

{{- define "bootstrap.waitForDepsInit" -}}
{{- if include "bootstrap.waitForEnabled" . | eq "true" }}
initContainers:
  - name: wait-for-deps
    image: {{ include "bootstrap.containerImage" . }}
    imagePullPolicy: Always
    command:
      - python
      - -c
      - |
        import socket, sys, time
        targets = [
            ({{ include "bootstrap.postgresHost" . | quote }}, {{ include "bootstrap.postgresPort" . }}),
            ({{ include "bootstrap.neo4jHost" . | quote }}, {{ include "bootstrap.neo4jPort" . }}),
        ]
        timeout = {{ include "bootstrap.waitForTimeoutSeconds" . }}
        deadline = time.time() + timeout
        for host, port in targets:
            print(f"Waiting for {host}:{port} (timeout={timeout}s)...", flush=True)
            while True:
                try:
                    with socket.create_connection((host, port), timeout=2):
                        print(f"{host}:{port} is up", flush=True)
                        break
                except OSError as exc:
                    if time.time() >= deadline:
                        print(f"Timed out waiting for {host}:{port}: {exc}", file=sys.stderr)
                        sys.exit(1)
                    time.sleep(2)
        print("Dependencies ready", flush=True)
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    volumeMounts:
      - name: tmp
        mountPath: /tmp
{{- end }}
{{- end }}

{{/* ── Ingestion ────────────────────────────────────────────────────────── */}}

{{- define "ingestion.schedule" -}}
{{- .Values.ingestion.schedule | default "*/10 * * * *" -}}
{{- end }}

{{- define "ingestion.adapterId" -}}
{{- .Values.ingestion.adapterId | default "opensky_flights" -}}
{{- end }}

{{- define "ingestion.waitForEnabled" -}}
{{- $waitFor := (.Values.ingestion.waitFor | default dict) -}}
{{- if kindIs "bool" $waitFor.enabled }}{{ $waitFor.enabled }}{{ else }}true{{ end -}}
{{- end }}

{{- define "ingestion.waitForTimeoutSeconds" -}}
{{- $waitFor := (.Values.ingestion.waitFor | default dict) -}}
{{- $waitFor.timeoutSeconds | default 300 -}}
{{- end }}

{{- define "ingestion.llmBaseUrl" -}}
{{- $llm := (.Values.ingestion.llm | default dict) -}}
{{- $llm.baseUrl | default (include "api.llmBaseUrl" .) -}}
{{- end }}

{{- define "ingestion.llmBackend" -}}
{{- $llm := (.Values.ingestion.llm | default dict) -}}
{{- $llm.backend | default (include "api.llmBackend" .) -}}
{{- end }}

{{- define "ingestion.llmApiKey" -}}
{{- $llm := (.Values.ingestion.llm | default dict) -}}
{{- $llm.apiKey | default (include "api.llmApiKey" .) -}}
{{- end }}

{{- define "ingestion.generationModelId" -}}
{{- $models := (.Values.ingestion.models | default dict) -}}
{{- $models.generation | default (include "api.generationModelId" .) -}}
{{- end }}

{{- define "ingestion.embeddingModelId" -}}
{{- $models := (.Values.ingestion.models | default dict) -}}
{{- $models.embedding | default (include "api.embeddingModelId" .) -}}
{{- end }}

{{- define "ingestion.embeddingDimension" -}}
{{- $models := (.Values.ingestion.models | default dict) -}}
{{- $models.embeddingDimension | default (include "api.embeddingDimension" .) -}}
{{- end }}

{{- define "ingestion.enabledDomains" -}}
{{- .Values.ingestion.enabledDomains | default (include "api.enabledDomains" .) -}}
{{- end }}

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
{{- $v := .Values.ingestion -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- $host := coalesce $pg.host $globalPg.host "postgres" -}}
{{- $port := coalesce $pg.port $globalPg.port 5432 -}}
{{- $user := coalesce $pg.user $pg.username $globalPg.user $globalPg.username "sim" -}}
{{- $password := required "postgres.password or global.postgres.password is required" (coalesce $pg.password $globalPg.password "") -}}
{{- $database := coalesce $pg.database $globalPg.database "sim" -}}
postgresql://{{ $user }}:{{ $password }}@{{ $host }}:{{ $port }}/{{ $database }}
{{- end }}

{{- define "ingestion.neo4jURI" -}}
{{- $v := .Values.ingestion -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- $host := coalesce $nj.host $globalNeo4j.host "neo4j" -}}
{{- $port := coalesce $nj.port $globalNeo4j.port 7687 -}}
bolt://{{ $host }}:{{ $port }}
{{- end }}

{{- define "ingestion.neo4jUser" -}}
{{- $v := .Values.ingestion -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.user $globalNeo4j.user "neo4j" -}}
{{- end }}

{{- define "ingestion.neo4jPassword" -}}
{{- $v := .Values.ingestion -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- required "neo4j.password or global.neo4j.password is required" (coalesce $nj.password $globalNeo4j.password "") -}}
{{- end }}

{{- define "ingestion.postgresHost" -}}
{{- $v := .Values.ingestion -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.host $globalPg.host "postgres" -}}
{{- end }}

{{- define "ingestion.postgresPort" -}}
{{- $v := .Values.ingestion -}}
{{- $globalPg := (.Values.global | default dict).postgres | default dict -}}
{{- $pg := $v.postgres | default dict -}}
{{- coalesce $pg.port $globalPg.port 5432 -}}
{{- end }}

{{- define "ingestion.neo4jHost" -}}
{{- $v := .Values.ingestion -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.host $globalNeo4j.host "neo4j" -}}
{{- end }}

{{- define "ingestion.neo4jPort" -}}
{{- $v := .Values.ingestion -}}
{{- $globalNeo4j := (.Values.global | default dict).neo4j | default dict -}}
{{- $nj := $v.neo4j | default dict -}}
{{- coalesce $nj.port $globalNeo4j.port 7687 -}}
{{- end }}

{{- define "ingestion.container" -}}
{{- $v := .Values.ingestion -}}
- name: ingestion
  image: {{ include "ingestion.containerImage" . }}
  imagePullPolicy: Always
  command:
    - python
    - -m
    - src.ingestion
    - --adapter
    - {{ include "ingestion.adapterId" . | quote }}
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
      value: {{ include "ingestion.llmBaseUrl" . | quote }}
    - name: LLM_BACKEND
      value: {{ include "ingestion.llmBackend" . | quote }}
    - name: OPENAI_API_KEY
      value: {{ include "ingestion.llmApiKey" . | quote }}
    - name: GENERATION_MODEL_ID
      value: {{ include "ingestion.generationModelId" . | quote }}
    - name: EMBEDDING_MODEL_ID
      value: {{ include "ingestion.embeddingModelId" . | quote }}
    - name: EMBEDDING_DIMENSION
      value: {{ include "ingestion.embeddingDimension" . | quote }}
    - name: ENABLED_DOMAINS
      value: {{ include "ingestion.enabledDomains" . | quote }}
  {{- with $v.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  volumeMounts:
    - name: tmp
      mountPath: /tmp
{{- end }}

{{- define "ingestion.containerImage" -}}
{{- $v := .Values.ingestion -}}
{{- if $v.image -}}
{{- $v.image -}}
{{- else -}}
{{- $global := .Values.global | default dict -}}
{{- $registry := $global.registry | default "quay.io/rh-ai-quickstart" -}}
{{- $tag := $global.imageTag | default "latest" -}}
{{- $images := $global.images | default dict -}}
{{- $name := $v.imageName | default ($images.app | default "general-sim-api") -}}
{{- printf "%s/%s:%s" $registry $name $tag -}}
{{- end -}}
{{- end -}}

{{- define "ingestion.waitForDepsInit" -}}
{{- if include "ingestion.waitForEnabled" . | eq "true" }}
initContainers:
  - name: wait-for-deps
    image: {{ include "ingestion.containerImage" . }}
    imagePullPolicy: Always
    command:
      - python
      - -c
      - |
        import socket, sys, time
        targets = [
            ({{ include "ingestion.postgresHost" . | quote }}, {{ include "ingestion.postgresPort" . }}),
            ({{ include "ingestion.neo4jHost" . | quote }}, {{ include "ingestion.neo4jPort" . }}),
        ]
        timeout = {{ include "ingestion.waitForTimeoutSeconds" . }}
        deadline = time.time() + timeout
        for host, port in targets:
            print(f"Waiting for {host}:{port} (timeout={timeout}s)...", flush=True)
            while True:
                try:
                    with socket.create_connection((host, port), timeout=2):
                        print(f"{host}:{port} is up", flush=True)
                        break
                except OSError as exc:
                    if time.time() >= deadline:
                        print(f"Timed out waiting for {host}:{port}: {exc}", file=sys.stderr)
                        sys.exit(1)
                    time.sleep(2)
        print("Dependencies ready", flush=True)
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    volumeMounts:
      - name: tmp
        mountPath: /tmp
{{- end }}
{{- end }}

{{/* ── Llama Stack run-config (parent override) ─────────────────────────── */}}

{{- define "general-simulation.llamaStackValues" -}}
{{- index .Values "llama-stack" | default dict -}}
{{- end }}

{{- define "general-simulation.llamaStackMergeModels" -}}
  {{- $root := . }}
  {{- $ls := index .Values "llama-stack" | default dict -}}
  {{- $globalModels := (.Values.global | default dict).models | default dict -}}
  {{- $localModels := $ls.models | default dict -}}
  {{- $merged := merge $globalModels $localModels -}}
  {{- range $key, $model := $merged }}
    {{- if not $model.url }}
      {{- $url := printf "https://%s.%s.svc.cluster.local/v1" $key $root.Release.Namespace }}
      {{- if ($ls.rawDeploymentMode | default true) }}
        {{- $url = printf "http://%s-vllm.%s.svc.cluster.local/v1" $key $root.Release.Namespace }}
      {{- end }}
      {{- $_ := set $merged $key (merge $model (dict "url" $url)) }}
    {{- end }}
  {{- end }}
  {{- toJson $merged -}}
{{- end }}

{{- define "general-simulation.llamaStackMergeMcpServers" -}}
  {{- $ls := index .Values "llama-stack" | default dict -}}
  {{- $globalServers := index (.Values.global | default dict) "mcp-servers" | default dict -}}
  {{- $localServers := index $ls "mcp-servers" | default dict -}}
  {{- toJson (merge $globalServers $localServers) -}}
{{- end }}

{{- define "general-simulation.llamaStackHasEnabledModels" -}}
  {{- $found := false -}}
  {{- $models := include "general-simulation.llamaStackMergeModels" . | fromJson -}}
  {{- range $key, $model := $models }}
    {{- if and $model.enabled (ne $key "remote-llm") }}
      {{- $found = true -}}
    {{- end }}
  {{- end }}
  {{- if $found }}true{{- end -}}
{{- end }}

{{- define "general-simulation.llamaStackEmbeddingTrustRemoteCode" -}}
{{- $model := include "api.embeddingModelId" . -}}
{{- if contains "nomic" $model }}true{{ else }}false{{ end -}}
{{- end }}
