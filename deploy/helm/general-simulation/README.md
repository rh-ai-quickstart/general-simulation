# general-simulation Helm chart

Umbrella chart for the General Simulation & Impact-Reasoning Platform.

Inference always goes through **Llama Stack**. Three modes:

| Mode | Stack upstream | Extra requirements |
|------|----------------|--------------------|
| **maas** (default) | LiteMaaS (`external-model/llama-scout-17b`) | `MAAS_API_TOKEN` |
| **openai** | OpenAI (`api.openai.com`) | `OPENAI_API_KEY` |
| **local** | In-cluster `llm-service` (vLLM) | OpenShift AI + `HF_TOKEN` |

Prefer `make deploy` from the repo root. Consumer values live at **[`helm/values.yaml`](../../../helm/values.yaml)**.

**Values mapping:** [`VALUES_MAPPING.md`](../../../VALUES_MAPPING.md) — how consumer
values flow into subcharts, `global.*`, secrets, and LLM modes.

## Modes of install

| Install | How | Namespace |
|---------|-----|-----------|
| **Standalone** | `make deploy` or `helm upgrade --install … -f helm/values.yaml` | Whatever `-n` you pass |
| **Subchart** | Parent `Chart.yaml` dependency + values | Same as the parent release |

In-cluster defaults use **short Service names** (`postgres`, `neo4j`, `llamastack`, `general-sim-api`). Cross-namespace clients should use FQDNs such as `general-sim-api.<namespace>.svc:8000`.

**Post-deploy smoke test:** `SEED_MODE=cluster make smoke-test` seeds the UK airspace closure demo and runs `POST /query`. JSON admin API at `/admin/*` remains for automation. Disable the API Route on Kind: `--set api.route.enabled=false`.

## Chart repository (GitHub Pages)

Once published:

```bash
helm repo add general-simulation https://robertsandoval.github.io/general-simulation
helm repo update
helm search repo general-simulation
```

Parent / subchart dependency:

```yaml
dependencies:
  - name: general-simulation
    version: 0.0.1
    repository: https://robertsandoval.github.io/general-simulation
    condition: general-simulation.enabled
```

Legacy clients may still pin `0.2.0` until that version is retired from the chart repo (see below).


## Recommended install (Makefile)

```bash
# LiteMaaS via Llama Stack (default)
make deploy \
  PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> \
  MAAS_API_TOKEN=<token>

# OpenAI via Llama Stack
make deploy LLM_MODE=openai \
  PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> \
  OPENAI_API_KEY=<key>

# In-cluster vLLM via Llama Stack
make deploy LLM_MODE=local \
  PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> \
  HF_TOKEN=<hf-token>
```

## Manual Helm install (maas default)

```bash
oc new-project general-simulation   # or --create-namespace below

helm repo add neo4j https://helm.neo4j.com/neo4j
helm repo add ai-architecture-charts https://rh-ai-quickstart.github.io/ai-architecture-charts
helm dependency update deploy/helm/general-simulation

helm upgrade --install general-simulation ./deploy/helm/general-simulation \
  --namespace general-simulation --create-namespace \
  -f helm/values.yaml \
  --set global.registry=quay.io/<your-org> \
  --set-string global.postgres.password=<PG_PASSWORD> \
  --set-string global.neo4j.password=<NEO4J_PASSWORD> \
  --set-string global.models.external-model.apiToken=<MAAS_API_TOKEN> \
  --wait --timeout 15m
```

For **openai** mode, add `-f helm/values-openai.yaml` and pass
`global.models.openai.apiToken` instead of the MaaS token.

For **local** mode, add `-f helm/values-local.yaml` and pass
`llm-service.secret.hf_token`.

Optional: copy `helm/values-secrets.yaml.example` to `helm/values-secrets.yaml` (gitignored)
and add `-f helm/values-secrets.yaml` instead of individual `--set-string` secret flags.

On **Kind / plain Kubernetes**, disable OpenShift SCC resources:

```bash
--set openshift.neo4j.scc.enabled=false
```

API and ingestion always call `http://llamastack:8321/v1` — never OpenAI or vLLM directly.

## Client URL

| Client location | `GENERAL_SIMULATION_BASE_URL` |
|-----------------|-------------------------------|
| Same namespace (subchart) | `http://general-sim-api:8000` |
| Other namespace | `http://general-sim-api.<gen-sim-ns>.svc:8000` |

## Component toggles

| Key | Default | Notes |
|-----|---------|--------|
| `llm.mode` | `maas` | Use `helm/values-openai.yaml` / `helm/values-local.yaml` overlays |
| `global.postgres.password` | `""` | Required at install — shared by all subcharts |
| `global.neo4j.password` | `""` | Required at install — shared by all subcharts |
| `postgres.enabled` | `true` | Platform Postgres (pgvector + PostGIS) |
| `neo4j.enabled` | `true` | Official `neo4j/neo4j` chart |
| `bootstrap.enabled` | `true` | Schema Job (hook) |
| `llama-stack.enabled` | `true` | Inference gateway |
| `llm-service.enabled` | `false` | In-cluster vLLM (local mode) |
| `api.enabled` | `true` | FastAPI |
| `ingestion.enabled` | `true` | CronJob + optional run-on-deploy hook Job |
| `ingestion.runOnDeploy.enabled` | `true` | First ingestion pull right after `helm install/upgrade` (no 10‑min wait) |

## Publishing a new chart version

1. Bump `version` in `Chart.yaml`.
2. Tag `chart-v<version>` (must match `Chart.yaml`, e.g. `chart-v0.0.1`) or run the **Publish Helm chart** workflow.
3. CI packages the chart and updates GitHub Pages (`index.yaml` + `.tgz`). Older `.tgz` files are kept (`keep_files: true`).

### Dual versions (e.g. 0.2.0 + 0.0.1)

The chart repo can host multiple versions. Clients pin `dependencies.version` explicitly.
`helm install` without `--version` picks the **highest** semver (so `0.2.0` stays “latest” until it is removed).

To publish **0.2.0** then **0.0.1**:

```bash
# From a commit where Chart.yaml is 0.2.0
git tag chart-v0.2.0 && git push origin chart-v0.2.0

# After bumping Chart.yaml to 0.0.1 and committing
git tag chart-v0.0.1 && git push origin chart-v0.0.1
```

### Retiring an old chart version (e.g. remove 0.2.0 after 0.0.1 is validated)

1. Check out the `gh-pages` branch.
2. Delete `general-simulation-0.2.0.tgz`.
3. Regenerate the index (from the repo root, with only remaining `.tgz` files on `gh-pages`):

   ```bash
   helm repo index . --url https://robertsandoval.github.io/general-simulation
   ```

4. Commit and push `gh-pages`.
5. Tell clients on `0.2.0` to bump their parent chart to `0.0.1` and run `helm dependency update`.
