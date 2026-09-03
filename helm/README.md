# Helm values (standalone deploy)

Consumer-facing values for installing **general-simulation** from this repo.

| File | Purpose |
|------|---------|
| [`values.yaml`](values.yaml) | **Default** — LiteMaaS via `external-model/llama-scout-17b` |
| [`values-openai.yaml`](values-openai.yaml) | Overlay — OpenAI (`LLM_MODE=openai`) |
| [`values-local.yaml`](values-local.yaml) | Overlay — in-cluster vLLM (`LLM_MODE=local`) |
| [`values-secrets.yaml.example`](values-secrets.yaml.example) | Template for passwords/tokens (copy to `values-secrets.yaml`) |

## Quick start

```bash
cp helm/values-secrets.yaml.example helm/values-secrets.yaml
# edit helm/values-secrets.yaml — then:
make deploy
```

Secrets resolve in this order (highest wins for `--set`; file used when make/env empty):

1. `make deploy PG_PASSWORD=...` (or `export PG_PASSWORD=...`)
2. `helm/values-secrets.yaml`

## LLM modes

| Mode | Command | Token in secrets file |
|------|---------|------------------------|
| **maas** (default) | `make deploy` | `global.models.external-model.apiToken` |
| openai | `make deploy LLM_MODE=openai` | `global.models.openai.apiToken` |
| local | `make deploy LLM_MODE=local` | `llm-service.secret.hf_token` |

## Post-deploy smoke test

After deploy, seed the UK airspace closure demo and run a query:

```bash
SEED_MODE=cluster NAMESPACE=general-simulation make smoke-test
```

Or seed and query separately:

```bash
oc exec -n general-simulation deployment/general-sim-api -- seed-demo
./demo.sh   # defaults to opensky-uk-closure-001
```

## Ingestion on deploy

By default, ingestion runs once immediately after deploy (Helm hook Job), then every 10 minutes via CronJob. Disable the initial run:

```yaml
ingestion:
  runOnDeploy:
    enabled: false
```

Override a single secret without editing the file:

```bash
make deploy MAAS_API_TOKEN='override-token'
```

Or with Helm directly:

```bash
helm upgrade --install general-simulation ./deploy/helm/general-simulation \
  --namespace general-simulation --create-namespace \
  -f helm/values.yaml \
  -f helm/values-secrets.yaml
```

Chart templates live under [`deploy/helm/general-simulation/`](../deploy/helm/general-simulation/).

**Values flow:** see [`VALUES_MAPPING.md`](../VALUES_MAPPING.md) for how consumer
`helm/values*.yaml` maps into the umbrella chart and subcharts.
