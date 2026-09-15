#!/usr/bin/env bash
# Seed demo data and run the UK airspace closure scenario against a deployed API.
#
# Usage:
#   ./scripts/smoke-uk-closure.sh
#   API_BASE=https://my-api.example.com ./scripts/smoke-uk-closure.sh
#   SEED_MODE=cluster NAMESPACE=general-simulation ./scripts/smoke-uk-closure.sh
#
# SEED_MODE:
#   auto    — cluster when general-sim-api exists in NAMESPACE, else local (default)
#   local   — uv run seed-demo from this repo (needs DB env / port-forwards)
#   cluster — oc exec into general-sim-api; health/query hit localhost:8000 in-pod
#             (avoids OpenShift Route timeouts on long /query LLM calls)
set -euo pipefail

PY="${SMOKE_PYTHON:-/app/.venv/bin/python}"
CLUSTER_DEPLOY="${SMOKE_DEPLOY:-deployment/general-sim-api}"
CLUSTER_CONTAINER="${SMOKE_CONTAINER:-api}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-600}"

NAMESPACE="${NAMESPACE:-general-simulation}"
API_BASE="${API_BASE:-}"

_cluster_resources_present() {
  local name="${1:-general-sim-api}"
  oc get deployment "$name" -n "$NAMESPACE" &>/dev/null ||
    oc get route "$name" -n "$NAMESPACE" &>/dev/null
}

_resolve_seed_mode() {
  if [[ -n "${SEED_MODE:-}" && "${SEED_MODE}" != "auto" ]]; then
    printf '%s' "$SEED_MODE"
    return
  fi
  if ! command -v oc &>/dev/null; then
    printf 'local'
    return
  fi
  local deploy="${SMOKE_DEPLOY:-deployment/general-sim-api}"
  local name="${deploy#deployment/}"
  if _cluster_resources_present "$name"; then
    printf 'cluster'
    return
  fi
  printf 'local'
}

SEED_MODE="$(_resolve_seed_mode)"

SCENARIO_ID="opensky-uk-closure-001"
QUESTION="UK airspace is closed due to a NATS GPS failure. Which aircraft are affected, what diversions should be issued, and what is the estimated cost of impact?"

QUERY_JSON="$(SCENARIO_ID="$SCENARIO_ID" QUESTION="$QUESTION" python3 - <<'PY'
import json, os
print(json.dumps({
    "scenario_id": os.environ["SCENARIO_ID"],
    "question": os.environ["QUESTION"],
    "allow_live_ingestion": False,
}))
PY
)"

if [[ -z "$API_BASE" ]] && command -v oc &>/dev/null; then
  host="$(oc get route general-sim-api -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$host" ]]; then
    API_BASE="https://${host}"
  fi
fi
API_BASE="${API_BASE:-http://localhost:8000}"

_cluster_http() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  oc exec -n "$NAMESPACE" "$CLUSTER_DEPLOY" -c "$CLUSTER_CONTAINER" -- \
    env METHOD="$method" PATH="$path" BODY="$body" TIMEOUT="$QUERY_TIMEOUT" \
    "$PY" -c '
import json, os, sys
import httpx

method = os.environ["METHOD"]
path = os.environ["PATH"]
timeout = float(os.environ["TIMEOUT"])
url = f"http://127.0.0.1:8000{path}"
body = os.environ.get("BODY", "")
try:
    if method == "GET":
        resp = httpx.get(url, timeout=timeout)
    else:
        resp = httpx.post(
            url,
            content=body.encode() if body else b"{}",
            headers={"Content-Type": "application/json"},
            timeout=timeout,
        )
    resp.raise_for_status()
except httpx.HTTPStatusError as exc:
    print(exc.response.text, file=sys.stderr)
    sys.exit(exc.response.status_code)
except Exception as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
print(resp.text)
'
}

_curl_http() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local out_file="$4"
  local http_code
  if [[ "$method" == "GET" ]]; then
    http_code="$(curl -sk -o "$out_file" -w "%{http_code}" --max-time "$QUERY_TIMEOUT" "$url")"
  else
    http_code="$(curl -sk -o "$out_file" -w "%{http_code}" --max-time "$QUERY_TIMEOUT" \
      -X POST "$url" \
      -H "Content-Type: application/json" \
      -d "$body")"
  fi
  printf '%s' "$http_code"
}

_fail_http() {
  local label="$1"
  local code="$2"
  local body_file="$3"
  echo "ERROR: ${label} failed (HTTP ${code})." >&2
  if [[ -s "$body_file" ]]; then
    echo "--- response body ---" >&2
    cat "$body_file" >&2
  else
    echo "(empty body — common when an OpenShift Route times out before /query returns)" >&2
    echo "Tip: SEED_MODE=cluster uses in-pod HTTP and avoids Route limits." >&2
  fi
  exit 1
}

_cluster_seed() {
  local pod seed_script repo_root

  pod="$(oc get pod -n "$NAMESPACE" -l app.kubernetes.io/name=general-sim-api \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    echo "ERROR: no general-sim-api pod in namespace ${NAMESPACE}" >&2
    exit 1
  fi

  if oc exec -n "$NAMESPACE" "$CLUSTER_DEPLOY" -c "$CLUSTER_CONTAINER" -- \
      test -x /app/.venv/bin/seed-demo 2>/dev/null; then
    oc exec -n "$NAMESPACE" "$CLUSTER_DEPLOY" -c "$CLUSTER_CONTAINER" -- seed-demo
    return
  fi
  if oc exec -n "$NAMESPACE" "$CLUSTER_DEPLOY" -c "$CLUSTER_CONTAINER" -- \
      test -f /app/scripts/seed_demo.py 2>/dev/null; then
    oc exec -n "$NAMESPACE" "$CLUSTER_DEPLOY" -c "$CLUSTER_CONTAINER" -- \
      "$PY" /app/scripts/seed_demo.py
    return
  fi

  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  seed_script="${repo_root}/scripts/seed_demo.py"
  if [[ ! -f "$seed_script" ]]; then
    echo "ERROR: ${seed_script} not found." >&2
    echo "Rebuild the API image (make build && make deploy) or run smoke-test from the repo root." >&2
    exit 1
  fi
  echo "==> API image has no bundled seed script; copying from repo to pod /tmp/seed_demo.py"
  oc cp "$seed_script" "${NAMESPACE}/${pod}:/tmp/seed_demo.py" -c "$CLUSTER_CONTAINER"
  oc exec -n "$NAMESPACE" "$CLUSTER_DEPLOY" -c "$CLUSTER_CONTAINER" -- \
    "$PY" /tmp/seed_demo.py
}

echo "==> Seeding demo data (mode=${SEED_MODE})"
case "$SEED_MODE" in
  local)
    if command -v oc &>/dev/null; then
      deploy_name="${CLUSTER_DEPLOY#deployment/}"
      if _cluster_resources_present "$deploy_name"; then
        echo "ERROR: OpenShift resources exist in namespace '${NAMESPACE}' but seed mode is 'local'." >&2
        echo "Run: SEED_MODE=cluster make smoke-test" >&2
        exit 1
      fi
    fi
    uv run seed-demo
    ;;
  cluster)
    _cluster_seed
    ;;
  *)
    echo "ERROR: SEED_MODE must be 'auto', 'local', or 'cluster' (got: ${SEED_MODE})" >&2
    exit 1
    ;;
esac

health_file="$(mktemp)"
trap 'rm -f "$health_file" "$query_file"' EXIT
query_file="$(mktemp)"

echo ""
if [[ "$SEED_MODE" == "cluster" ]]; then
  echo "==> Health check (in-pod http://127.0.0.1:8000/health)"
  health_json="$(_cluster_http GET /health)"
  echo "$health_json" >"$health_file"
else
  echo "==> Health check (${API_BASE})"
  health_code="$(_curl_http GET "${API_BASE}/health" "" "$health_file")"
  if [[ "$health_code" != "200" ]]; then
    _fail_http "GET /health" "$health_code" "$health_file"
  fi
  health_json="$(cat "$health_file")"
fi
echo "$health_json" | python3 -m json.tool

if ! echo "$health_json" | python3 -c "
import json, sys
body = json.load(sys.stdin)
if body.get('agent_tool_choice') is not True:
    print(
        'ERROR: API image is missing agent_tool_choice health marker. '
        'Rebuild and redeploy: make build && make deploy',
        file=sys.stderr,
    )
    sys.exit(1)
"; then
  exit 1
fi

echo ""
echo "==> Running UK airspace closure query (timeout=${QUERY_TIMEOUT}s)"
echo "    scenario_id : ${SCENARIO_ID}"
echo "    question    : ${QUESTION}"
echo ""

if [[ "$SEED_MODE" == "cluster" ]]; then
  query_json="$(_cluster_http POST /query "$QUERY_JSON")"
  echo "$query_json" | tee "$query_file" | python3 -m json.tool
else
  query_code="$(_curl_http POST "${API_BASE}/query" "$QUERY_JSON" "$query_file")"
  if [[ "$query_code" != "200" ]]; then
    _fail_http "POST /query" "$query_code" "$query_file"
  fi
  cat "$query_file" | python3 -m json.tool
fi

if ! python3 -c "
import json, sys
body = json.load(open('$query_file'))
trace = body.get('tool_call_trace') or []
if not trace:
    print('ERROR: tool_call_trace is empty — LLM did not execute tools.', file=sys.stderr)
    sys.exit(1)
for record in trace:
    if record.get('tool_name') == 'run_ingestion_pull':
        print(
            'ERROR: smoke test must not call run_ingestion_pull '
            '(set allow_live_ingestion=false on /query).',
            file=sys.stderr,
        )
        sys.exit(1)
print(f'OK: {len(trace)} tool call(s) recorded')
"; then
  exit 1
fi

echo ""
echo "==> Smoke test complete."
