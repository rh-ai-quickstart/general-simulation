#!/usr/bin/env bash
set -euo pipefail

API_BASE="${API_BASE:-https://general-sim-api-general-sim.apps.ocp.sandoval.lab}"
SCENARIO_ID="${1:-opensky-uk-closure-001}"
QUESTION="${2:-UK airspace is closed due to a NATS GPS failure. Which aircraft are affected, what diversions should be issued, and what is the estimated cost of impact?}"

echo "==> Health check"
curl -sk "${API_BASE}/health" | python3 -m json.tool

echo ""
echo "==> Submitting query"
echo "    scenario_id : ${SCENARIO_ID}"
echo "    question    : ${QUESTION}"
echo ""

curl -sk -X POST "${API_BASE}/query" \
  -H "Content-Type: application/json" \
  -d "{\"scenario_id\": \"${SCENARIO_ID}\", \"question\": \"${QUESTION}\"}" \
  | python3 -m json.tool
