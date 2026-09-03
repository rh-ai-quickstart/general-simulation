#!/usr/bin/env bash
# Seed demo data and run the UK airspace closure scenario against a deployed API.
#
# Usage:
#   ./scripts/smoke-uk-closure.sh
#   API_BASE=https://my-api.example.com ./scripts/smoke-uk-closure.sh
#   SEED_MODE=cluster NAMESPACE=general-simulation ./scripts/smoke-uk-closure.sh
#
# SEED_MODE:
#   local   — uv run seed-demo from this repo (default; needs DB env / port-forwards)
#   cluster — oc exec into general-sim-api and run seed-demo in the pod
set -euo pipefail

NAMESPACE="${NAMESPACE:-general-simulation}"
SEED_MODE="${SEED_MODE:-local}"
API_BASE="${API_BASE:-}"

SCENARIO_ID="opensky-uk-closure-001"
QUESTION="UK airspace is closed due to a NATS GPS failure. Which aircraft are affected, what diversions should be issued, and what is the estimated cost of impact?"

if [[ -z "$API_BASE" ]] && command -v oc &>/dev/null; then
  host="$(oc get route general-sim-api -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$host" ]]; then
    API_BASE="https://${host}"
  fi
fi
API_BASE="${API_BASE:-http://localhost:8000}"

echo "==> Seeding demo data (mode=${SEED_MODE})"
case "$SEED_MODE" in
  local)
    uv run seed-demo
    ;;
  cluster)
    oc exec -n "$NAMESPACE" "deployment/general-sim-api" -- seed-demo
    ;;
  *)
    echo "ERROR: SEED_MODE must be 'local' or 'cluster' (got: ${SEED_MODE})" >&2
    exit 1
    ;;
esac

echo ""
echo "==> Health check (${API_BASE})"
health_json="$(curl -sk "${API_BASE}/health")"
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
echo "==> Running UK airspace closure query"
echo "    scenario_id : ${SCENARIO_ID}"
echo "    question    : ${QUESTION}"
echo ""

curl -sk -X POST "${API_BASE}/query" \
  -H "Content-Type: application/json" \
  -d "{\"scenario_id\": \"${SCENARIO_ID}\", \"question\": \"${QUESTION}\"}" \
  | tee /tmp/smoke-query.json \
  | python3 -m json.tool

if ! python3 -c "
import json, sys
body = json.load(open('/tmp/smoke-query.json'))
trace = body.get('tool_call_trace') or []
if not trace:
    print('ERROR: tool_call_trace is empty — LLM did not execute tools.', file=sys.stderr)
    sys.exit(1)
print(f'OK: {len(trace)} tool call(s) recorded')
"; then
  exit 1
fi

echo ""
echo "==> Smoke test complete."
