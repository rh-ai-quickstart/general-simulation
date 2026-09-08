# Archived deployment artifacts

These paths are **not** used by `make deploy` or the umbrella Helm chart. They are
kept for historical reference and migration notes.

## Replacement map

| Archived path | Replaced by |
|---------------|-------------|
| `openshift/api`, `openshift/ingestion`, `openshift/bootstrap`, `openshift/postgres` | Local subcharts under `helm/` |
| `openshift/llamastack` | `llama-stack` subchart ([ai-architecture-charts](https://rh-ai-quickstart.github.io/ai-architecture-charts)) |
| `openshift/vllm` | `llm-service` subchart (same repo) |
| `openshift/shared/configmaps.yaml` | `helm/templates/api/configmap.yaml` + ingestion CronJob env |
| `llamastack-helm/` | `llama-stack` subchart |
| `vllm-helm/` | `llm-service` subchart |
| `llamastack/run.yaml`, `llamastack/build.yaml` | Subchart-managed Llama Stack distribution |

## Active OpenShift helpers

`deploy/openshift/namespace.yaml` and `deploy/openshift/neo4j/` (ServiceAccount +
SCC binding) are still used by standalone `make deploy-neo4j`. The umbrella chart
creates equivalent Neo4j OpenShift resources via
`helm/templates/`.

## Authoritative install path

```bash
make deploy PG_PASSWORD=... NEO4J_PASSWORD=... MAAS_API_TOKEN=...
```

See [`helm/README.md`](../../helm/README.md).
