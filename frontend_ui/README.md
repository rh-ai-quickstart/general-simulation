# Simulation Console (work in progress)

> **Note:** The React admin UI is not shipped in the current API image. Use
> `seed-demo` and `make smoke-test` for post-deploy validation. This directory
> is kept for a future feature branch.

PatternFly 6 React UI for the General Simulation platform. Talks to the local FastAPI API (`/health`, `/admin/*`, `POST /query`) via the Vite dev proxy.

## Prerequisites

- Node.js 20+
- Local API stack running (Postgres, Neo4j, FastAPI) — see below

## Local three-terminal workflow

From the **repository root**:

```bash
# Terminal 1 — data stores
podman compose up -d
uv run python -m src.graph.bootstrap
uv run python scripts/seed_demo.py   # optional demo scenario opensky-uk-closure-001

# Terminal 2 — API
cp .env.example .env   # LLM_BACKEND=fake is fine for UI work without a model
uv run uvicorn src.api.app:app --reload --host 0.0.0.0 --port 8000

# Terminal 3 — UI (hot reload)
cd frontend_ui
npm install
npm run dev
```

Open **http://localhost:5173**.

### Dev server (API must be running)

```bash
cd frontend_ui
npm ci
npm run dev
# open http://localhost:5173
```

Vite proxies `/health`, `/query`, and `/admin` to `http://localhost:8000`. FastAPI also allows CORS from `localhost:5173` / `127.0.0.1:5173`.

> The production bundle is not embedded in the API image on this branch. Use the
> Vite dev server for local UI work until the console returns in a feature branch.

## Screens

| Route | Purpose |
|---|---|
| `/` | Overview — health + store/graph counts |
| `/data/import` | Upload graph files (entities + dependency edges) |
| `/data/entities` | Live Postgres entities (filter, search, detail drawer) |
| `/data/dependencies` | Manage dependency edges |
| `/data/ingestion` | Run domain adapters on demand |
| `/simulation/scenarios` | List / inject / delete simulation overlays |
| `/simulation/map` | Supply chain map — PostGIS positions + simulation highlight |
| `/simulation/graph` | Cytoscape dependency graph; `?scenario=` and `?highlight=` |
| `/reasoning/query` | Impact ReAct query + solver + tool-call trace |
| `/platform` | Read-only config + schema bootstrap |

After pulling map-related changes, **re-run** `uv run python scripts/seed_demo.py` from the repo root so Postgres gets demo lon/lat geometries. Without that, `/simulation/map` will be empty even if Neo4j already has the scenario.

## Build

```bash
VITE_BASE_PATH=/admin/ npm run build
```

Static assets land in `dist/`. The API Containerfile copies them to `src/api/static/console/` and serves them at `/admin/`.

## Disable on cluster

```yaml
# helm/values.yaml
api:
  admin:
    enabled: false   # hides UI; /admin/* JSON API remains for automation
```
