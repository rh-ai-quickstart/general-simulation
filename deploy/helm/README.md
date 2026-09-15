# general-simulation Helm chart

Single chart for the General Simulation platform. Postgres, neo4j (OpenShift
wiring), bootstrap, API, and ingestion are inline templates under
`templates/`; the Neo4j database itself, Llama Stack, and llm-service are
external subchart dependencies.

| File | Purpose |
|------|---------|
| [`values.yaml`](values.yaml) | **Default config** — component toggles, models, images |
| [`values-secrets.yaml.example`](values-secrets.yaml.example) | Template for passwords/tokens (copy to `values-secrets.yaml`) |

## Template layout

```
templates/
  api/                 # Deployment, Service, Route, ConfigMap, Secret
  bootstrap/           # Schema bootstrap Job
  ingestion/           # CronJob + optional hook Job
  neo4j/               # Secret neo4j-auth, ServiceAccount, SCC binding
  postgres/            # StatefulSet, Services, init ConfigMap, SCC binding
  llamastack-*.yaml    # Llama Stack run-config + pgvector Secret bridge
  _helpers.tpl         # Shared DSN, image, and wait-for helpers
```

## Quick start

```bash
cp deploy/helm/values-secrets.yaml.example deploy/helm/values-secrets.yaml
# edit deploy/helm/values-secrets.yaml — then:
make deploy
```

## Model providers

Enable providers in `values.yaml` via `global.models.<key>.enabled`. Point
`api.models.generation` at `<providerKey>/<model.id>`. Embeddings, LLM URL,
domains, route, and wait-for settings default in `templates/_helpers.tpl`.

## Component toggles

```yaml
postgres:
  enabled: true
bootstrap:
  enabled: true
api:
  enabled: true
ingestion:
  enabled: true   # shipped default in values.yaml is false
neo4j:
  enabled: true
llama-stack:
  enabled: true
llm-service:
  enabled: true   # set false when using MaaS/OpenAI only (no GPU)
```

Shipped defaults in `values.yaml` set `ingestion.enabled: false` until you
enable the CronJob. Domain keys (`api.enabledDomains`, `ingestion.adapterId`, etc.)
default via `templates/_helpers.tpl`.

**Values flow:** see [`VALUES_MAPPING.md`](../../docs/VALUES_MAPPING.md).
