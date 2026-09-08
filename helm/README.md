# general-simulation Helm chart

Single chart for the General Simulation platform. Postgres, bootstrap, API, and
ingestion are inline templates; external dependencies are neo4j, llama-stack,
and llm-service.

| File | Purpose |
|------|---------|
| [`values.yaml`](values.yaml) | **Default config** — component toggles, models, images |
| [`values-secrets.yaml.example`](values-secrets.yaml.example) | Template for passwords/tokens (copy to `values-secrets.yaml`) |

## Quick start

```bash
cp helm/values-secrets.yaml.example helm/values-secrets.yaml
# edit helm/values-secrets.yaml — then:
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
default via `templates/_helpers.tpl`; see `values-full.yaml` for overrides.

**Values flow:** see [`VALUES_MAPPING.md`](../VALUES_MAPPING.md).
