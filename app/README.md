# Applications

Standalone apps in this repository. Platform infrastructure (Helm, Postgres image) lives under [`deploy/`](../deploy/).

## `api/` — Python platform

FastAPI service, ingestion, graph (Neo4j), reasoning pipeline, and domain adapters.

| Item | Path |
|------|------|
| Source | `app/api/src/` |
| Domain packages | `app/api/domain/` |
| Tests | `app/api/tests/` |
| Seed scripts | `app/api/scripts/` |
| Container image | `app/api/Containerfile` → `make build-app` |
| OpenShift deploy | `deploy/helm/api` (and umbrella chart) |

**Local dev** (from repo root):

```bash
uv sync
podman compose up -d
uv run python -m src.graph.bootstrap
uv run uvicorn src.api.app:app --reload
```

## `frontend_ui/` — Simulation console

PatternFly React UI (Vite). Proxies to the API in dev.

```bash
cd app/frontend_ui && npm install && npm run dev
```

Open **http://localhost:5173**. See [`frontend_ui/README.md`](frontend_ui/README.md).
