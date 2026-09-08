# Values mapping reference

How Helm values flow through the `general-simulation` umbrella chart and its
subcharts.

For quick-start commands see [`helm/README.md`](helm/README.md). The chart
lives at [`helm/`](helm/).

---

## Mental model

### 1. Single chart directory

```mermaid
flowchart LR
  subgraph helm_dir [helm/]
    V[values.yaml]
    S[values-secrets.yaml]
    T[templates + subcharts]
  end

  V --> T
  S --> T
  M[make --set] --> T
```

All chart templates and default values live under **`helm/`**. Edit
`helm/values.yaml` for day-to-day config; put secrets in
`helm/values-secrets.yaml` (gitignored).

### 2. Chart → components

Postgres, neo4j (OpenShift wiring), bootstrap, API, and ingestion are **inline
templates** under `helm/templates/`. External subchart dependencies: the Neo4j
database (`neo4j/neo4j` chart), llama-stack, and llm-service.

```mermaid
flowchart TB
  U[general-simulation]

  U --> PG[postgres inline]
  U --> NJW[neo4j inline wiring]
  U --> NJ[neo4j subchart]
  U --> BS[bootstrap inline]
  U --> LS[llama-stack dep]
  U --> API[api inline]
  U --> ING[ingestion inline]
  U -. optional .-> VLLM[llm-service dep]

  NJW -. Secret SA SCC .-> NJ
```

Enable providers via `global.models.<key>.enabled`. Set `llm-service.enabled`
for in-cluster vLLM.

### 3. Scoped vs global keys

**Scoped** — e.g. `api.route.enabled` only affects the API chart.  
**Global** — e.g. `global.postgres.password` is copied into each subchart's
`.Values.global`.

### Merge priority (later wins)

```text
subchart defaults  →  helm/values.yaml  →  -f values-secrets.yaml  →  --set
```

---

## Value file inventory

| File | Role | Committed? |
|------|------|------------|
| [`helm/values.yaml`](helm/values.yaml) | **Default config** (bundled in published `.tgz`) | Yes |
| [`helm/values-secrets.yaml`](helm/values-secrets.yaml) | Passwords and API tokens | **No** (gitignored) |
| [`helm/values-secrets.yaml.example`](helm/values-secrets.yaml.example) | Template for secrets file | Yes |

---

## Standalone install: merge order

`make deploy` runs:

```text
helm upgrade --install general-simulation ./helm \
  [-f helm/values-secrets.yaml]     # if file exists
  --set global.registry=...
  --set global.imageTag=...
  --set global.images.app=...
  --set global.images.postgres=...
  [--set-string secrets from resolve-deploy-secrets.sh]
```

Chart `values.yaml` is loaded automatically (no `-f` needed).

### Secret resolution (`helm/resolve-deploy-secrets.sh`)

| Priority | Source | Example |
|----------|--------|---------|
| 1 (highest) | Non-empty `make` / env var | `make deploy PG_PASSWORD=secret` |
| 2 | `helm/values-secrets.yaml` | `global.postgres.password` |

Required secrets depend on `helm/values.yaml`:

| Condition | Required secret | YAML path |
|-----------|-----------------|-----------|
| Always | `PG_PASSWORD` | `global.postgres.password` |
| Always | `NEO4J_PASSWORD` | `global.neo4j.password` |
| `global.models.external-model.enabled` + `url` set | `MAAS_API_TOKEN` | `global.models.external-model.apiToken` |
| `global.models.nomic.enabled` + `url` set | token in secrets file | `global.models.nomic.apiToken` |
| `global.models.openai.enabled` + `url` set | `OPENAI_API_KEY` | `global.models.openai.apiToken` |
| `llm-service.enabled` | `HF_TOKEN` | `llm-service.secret.hf_token` |

---

## Component routing

Top-level keys `postgres`, `bootstrap`, `api`, `ingestion` configure inline
templates (guarded by `<component>.enabled`). External deps use the same keys
for subchart values.

| Parent key | Renders | `enabled` guard |
|------------|---------|-----------------|
| `postgres` | Inline StatefulSet, Services, SCC (`templates/postgres/`) | `postgres.enabled` |
| `openshift.neo4j` | Inline Secret, SA, SCC (`templates/neo4j/`) | `neo4j.enabled` + `openshift.neo4j.scc.enabled` (SA/SCC) |
| `bootstrap` | Inline schema Job (hook) | `bootstrap.enabled` |
| `api` | Inline Deployment, Service, Route | `api.enabled` |
| `ingestion` | Inline CronJob + hook Job | `ingestion.enabled` |
| `neo4j` | External Neo4j StatefulSet subchart | `neo4j.enabled` |
| `llama-stack` | External subchart | `llama-stack.enabled` |
| `llm-service` | External subchart | `llm-service.enabled` |

---

## Model providers

Enable providers in `global.models.<key>.enabled`. Point
`api.models.generation` at `<providerKey>/<model.id>`. Most api/bootstrap/postgres
settings default in `templates/_helpers.tpl`.

### Inference path (always via Llama Stack)

```text
api / ingestion  →  http://llamastack:8321/v1  →  upstream provider
```

### Embeddings (inline sentence-transformers)

Embeddings run inside the Llama Stack pod via the built-in
`sentence-transformers` provider. The umbrella chart overrides subchart
`run-config` to register the embedding model for `/v1/embeddings` (the
subchart alone only sets the vector-store default).

| Role | `api.models.*` | Provider |
|------|----------------|----------|
| Chat | `generation: external-model/llama-scout-17b` | `external-model` (MaaS) |
| Embed | `embedding: sentence-transformers/nomic-ai/nomic-embed-text-v1.5` | `sentence-transformers` (inline) |

Set `url` explicitly for every remote chat provider. Without `url`, the chart
defaults to in-cluster `http://<key>-vllm.<namespace>.svc.cluster.local/v1`.

---

## Umbrella-only templates

| Template | Reads | Creates |
|----------|-------|---------|
| [`neo4j/secret.yaml`](helm/templates/neo4j/secret.yaml) | `global.neo4j.password` | Secret `neo4j-auth` |
| [`neo4j/serviceaccount.yaml`](helm/templates/neo4j/serviceaccount.yaml) | `openshift.neo4j.scc.enabled` | OpenShift SA `neo4j-sa` |
| [`neo4j/scc-binding.yaml`](helm/templates/neo4j/scc-binding.yaml) | `openshift.neo4j.scc.enabled` | SCC ClusterRoleBinding |
| [`llamastack-pg-secret.yaml`](helm/templates/llamastack-pg-secret.yaml) | `global.postgres.*` | Secret `pgvector` |
| [`llamastack-run-config.yaml`](helm/templates/llamastack-run-config.yaml) | `api.models.embedding`, `global.models.*` | ConfigMap `general-sim-llamastack-config` (mounted by llama-stack) |

---

## Consuming as a parent subchart

Nest values under `general-simulation:` — same routing as standalone
`helm/values.yaml`.

---

## Debugging values

```bash
helm get values general-simulation -n general-simulation

helm template test ./helm \
  -f helm/values-secrets.yaml \
  --show-only templates/api/configmap.yaml
```

---

## Related docs

| Doc | Contents |
|-----|----------|
| [`helm/README.md`](helm/README.md) | Quick start, model providers, secrets |
| [`Makefile`](Makefile) | `make deploy`, per-component targets |
| [`README.md`](README.md) | Full OpenShift deployment guide |
