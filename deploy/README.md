# deploy/ layout

OpenShift deployment is **Helm-only** (`deploy/helm/`), driven by the root
[Makefile](../Makefile). The API image is built from [`app/api/Containerfile`](../app/api/Containerfile);
Postgres from `deploy/postgres/`.

## Quick reference

| Path | Used by |
|------|---------|
| `../app/api/Containerfile` | `make build-app`, `.github/workflows/publish-images.yml` |
| `postgres/` | `make build-postgres`, `compose.yaml` (init SQL mount) |
| `helm/` | `make deploy*`, `make lint-charts`, `make package-chart`, `.github/workflows/publish-helm-chart.yml` |

## Container images

```
app/api/Containerfile          # FastAPI app image (make build-app)
deploy/postgres/
├── Containerfile              # Custom Postgres image (AGE + pgvector + PostGIS)
└── init/
    └── 01_extensions.sql      # Mounted by compose.yaml; mirrored in helm/postgres ConfigMap
```

Default image registry: `quay.io/rh-ai-quickstart`

## Helm charts

```
deploy/helm/
├── general-simulation/        # Umbrella chart; published to GitHub Pages
├── postgres/                  # StatefulSet, Services, SCC binding, init SQL ConfigMap
├── neo4j/values.yaml          # Values overlay for official neo4j/neo4j chart
├── bootstrap/                 # Schema bootstrap Job (post-install hook)
├── vllm/                      # Optional GPU vLLM Deployment + PVC
├── api/                       # FastAPI Deployment, Service, Route, ConfigMap, Secret
└── ingestion/                 # Ingestion CronJob
```

**Makefile targets:**

| Target | Chart |
|--------|-------|
| `deploy-postgres` | `helm/postgres` |
| `deploy-neo4j` | `helm/neo4j/values.yaml` + official `neo4j/neo4j` chart |
| `deploy-bootstrap` | `helm/bootstrap` |
| `deploy-vllm` | `helm/vllm` |
| `deploy-api` | `helm/api` |
| `deploy-ingestion` | `helm/ingestion` |
| `deploy-umbrella` | `helm/general-simulation` |
| `lint-charts` | all local charts + umbrella |
| `package-chart` | `helm/general-simulation` |
| `test-charts` | `helm unittest` on postgres, bootstrap, vllm, api, ingestion |

## Helm chart tests

Unit tests live under each chart's `tests/` directory and run via [helm-unittest](https://github.com/helm-unittest/helm-unittest):

```bash
# Install once
helm plugin install https://github.com/helm-unittest/helm-unittest

# Run all chart tests
make test-charts

# Or run Python + Helm together
make test
```

## Chart repository (subchart consumers)

Published to GitHub Pages for parent charts (e.g. ai-supply-chain-agent):

```bash
helm repo add general-simulation https://rh-ai-quickstart.github.io/general-simulation
helm repo update
```

See [helm/general-simulation/README.md](helm/general-simulation/README.md) for install examples.

## Subchart contract

Parent charts should depend on `deploy/helm/general-simulation` and preserve these stable interfaces:

| Contract | Value |
|----------|-------|
| API Service | `general-sim-api:8000` |
| Image overrides | `postgres.image`, `api.image`, `bootstrap.image`, `ingestion.image` |
| Password sync | `postgres.postgres.password`, `api.postgres.password`, `bootstrap.postgres.password`, `ingestion.postgres.password` (+ neo4j equivalents) |

Bump chart minor/major versions only with coordinated consumer updates.
