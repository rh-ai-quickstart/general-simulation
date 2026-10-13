# general-simulation Helm chart

Single chart for the General Simulation platform. Postgres, neo4j (OpenShift
wiring), bootstrap, API, and ingestion are inline templates under
`templates/`; the Neo4j database itself, Llama Stack, and llm-service are
external subchart dependencies.

| File | Purpose |
|------|---------|
| [`values.yaml`](values.yaml) | **Default config** — component toggles, models, images |
| [`values-kind.yaml`](values-kind.yaml) | Kind / plain Kubernetes CI overrides (no Routes, fake LLM, demo secrets) |
| [`values-secrets.yaml.example`](values-secrets.yaml.example) | Template for passwords/tokens (copy to `values-secrets.yaml`) |

## Template layout

```
templates/
  api/                 # Deployment, Service, Route, ConfigMap, Secret
  bootstrap/           # Schema bootstrap Job
  ingestion/           # CronJob + optional hook Job
  neo4j/               # Secret neo4j-auth; optional SA + SCC binding (legacy anyuid)
  postgres/            # StatefulSet, Services, init ConfigMap
  llamastack-*.yaml    # Llama Stack run-config + pgvector Secret bridge
  _helpers.tpl         # Shared DSN, image, and wait-for helpers
```

## Quick start

```bash
# Create/switch to the OpenShift project once (Helm does not create the namespace)
oc new-project general-simulation || oc project general-simulation

cp deploy/helm/values-secrets.yaml.example deploy/helm/values-secrets.yaml
# edit deploy/helm/values-secrets.yaml — then build (includes general-sim-neo4j) and deploy:
make build
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

## Kind / local Kubernetes smoke

CI and local verification use Kind with a local registry (`localhost:5001`),
`values-kind.yaml` (Routes off, Llama Stack off, `api.llm.backend: fake`), then
API checks: `GET /health`, demo seed, `POST /query`.

**RAM:** Neo4j’s chart requires at least 2Gi. Local Podman VMs should be ≥8Gi —
run `make kind-preflight` first. GitHub `ubuntu-latest` is fine.

**UIDs:** Kind has no OpenShift SCC, so `values-kind.yaml` pins Postgres to UID
999 and Neo4j to UID 7474. Without that, pods stay in `CreateContainerConfigError`
(`runAsNonRoot` with a root or non-numeric image USER).

```bash
# One-shot local path (Podman + Kind)
make local-kind-smoke-test

# Or step by step:
bash scripts/ci/kind-with-registry.sh
make kind-build-images REGISTRY=localhost:5001
make kind-push-images REGISTRY=localhost:5001 PUSH_EXTRA_ARGS=--tls-verify=false
make helm-install-kind REGISTRY=localhost:5001
make kind-verify

# Reuse an existing cluster / images:
make local-kind-smoke-test LOCAL_KIND_SMOKE_ARGS='--skip-build'
make local-kind-smoke-test LOCAL_KIND_SMOKE_ARGS='--recreate --cleanup'
```

GitHub Actions: [`.github/workflows/kind-helm-smoke.yml`](../../.github/workflows/kind-helm-smoke.yml)
uses [`.github/actions/kind`](../../.github/actions/kind/action.yaml).
