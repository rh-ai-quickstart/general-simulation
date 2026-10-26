#!/usr/bin/env bash
# Post-deploy checks for Kind + Helm install (used by kind-helm-smoke workflow).
# API-only: /health, seed demo scenarios, POST /query (expects LLM_BACKEND=fake).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

NAMESPACE="${NAMESPACE:-general-simulation}"
HELM_RELEASE="${HELM_RELEASE:-general-simulation}"
API_PF_PORT="${API_PF_PORT:-18000}"
CURL_MAX_TIME="${CURL_MAX_TIME:-120}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-120}"
SCENARIO_ID="${SCENARIO_ID:-opensky-uk-closure-001}"
QUESTION="${QUESTION:-UK airspace is closed due to a NATS GPS failure. Which aircraft are affected?}"

log() { echo ">>> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

body_contains() {
  local needle="$1"
  local body="$2"
  [[ "${body}" == *"${needle}"* ]]
}

cleanup() {
  if [ -n "${API_PF_PID:-}" ] && kill -0 "${API_PF_PID}" 2>/dev/null; then
    kill "${API_PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

wait_for_url() {
  local url="$1"
  local attempts="${2:-30}"
  local i
  for i in $(seq 1 "${attempts}"); do
    if curl -sf --max-time "${CURL_MAX_TIME}" "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

curl_body() {
  local url="$1"
  curl -sf --max-time "${CURL_MAX_TIME}" "${url}"
}

seed_demo() {
  log "Seeding demo scenarios via kubectl exec (seed-demo)"
  kubectl wait -n "${NAMESPACE}" --for=condition=available \
    deployment/general-sim-api --timeout=180s

  if kubectl exec -n "${NAMESPACE}" deploy/general-sim-api -c api -- \
      test -x /app/.venv/bin/seed-demo 2>/dev/null; then
    kubectl exec -n "${NAMESPACE}" deploy/general-sim-api -c api -- seed-demo
    return
  fi
  if kubectl exec -n "${NAMESPACE}" deploy/general-sim-api -c api -- \
      test -f /app/scripts/seed_demo.py 2>/dev/null; then
    kubectl exec -n "${NAMESPACE}" deploy/general-sim-api -c api -- \
      /app/.venv/bin/python /app/scripts/seed_demo.py
    return
  fi

  local seed_script="${ROOT_DIR}/scripts/seed_demo.py"
  [[ -f "${seed_script}" ]] || fail "missing seed script: ${seed_script}"
  local pod
  pod="$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=general-sim-api \
    -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${pod}" ]] || fail "no general-sim-api pod in namespace ${NAMESPACE}"
  log "API image has no bundled seed script; copying from repo"
  kubectl cp "${seed_script}" "${NAMESPACE}/${pod}:/tmp/seed_demo.py" -c api
  kubectl exec -n "${NAMESPACE}" deploy/general-sim-api -c api -- \
    /app/.venv/bin/python /tmp/seed_demo.py
}

log "Helm release status"
helm status "${HELM_RELEASE}" --namespace "${NAMESPACE}"

log "Workloads in namespace ${NAMESPACE}"
kubectl get deploy,sts,svc,pods -n "${NAMESPACE}"

log "Expect general-sim-api Deployment Available"
kubectl wait -n "${NAMESPACE}" --for=condition=available \
  deployment/general-sim-api --timeout=180s

log "Port-forward API Service"
kubectl port-forward -n "${NAMESPACE}" svc/general-sim-api \
  "${API_PF_PORT}:8000" >/tmp/kind-pf-api.log 2>&1 &
API_PF_PID=$!
wait_for_url "http://127.0.0.1:${API_PF_PORT}/health" 45 \
  || fail "API /health not ready (see /tmp/kind-pf-api.log)"

HEALTH=$(curl_body "http://127.0.0.1:${API_PF_PORT}/health")
body_contains '"status": "ok"' "${HEALTH}" || body_contains '"status":"ok"' "${HEALTH}" \
  || fail "unexpected /health body: ${HEALTH}"
body_contains 'reachable' "${HEALTH}" || fail "/health db not reachable: ${HEALTH}"
body_contains 'agent_tool_choice' "${HEALTH}" || fail "/health missing agent_tool_choice marker: ${HEALTH}"
log "PASS GET /health"

seed_demo
log "PASS demo seed"

QUERY_JSON="$(SCENARIO_ID="${SCENARIO_ID}" QUESTION="${QUESTION}" python3 - <<'PY'
import json, os
print(json.dumps({
    "scenario_id": os.environ["SCENARIO_ID"],
    "question": os.environ["QUESTION"],
    "allow_live_ingestion": False,
}))
PY
)"

log "POST /query (FakeLLMClient; timeout=${QUERY_TIMEOUT}s)"
QUERY=$(curl -sf --max-time "${QUERY_TIMEOUT}" \
  -X POST "http://127.0.0.1:${API_PF_PORT}/query" \
  -H 'Content-Type: application/json' \
  -d "${QUERY_JSON}") \
  || fail "POST /query failed"

body_contains "\"scenario_id\": \"${SCENARIO_ID}\"" "${QUERY}" \
  || body_contains "\"scenario_id\":\"${SCENARIO_ID}\"" "${QUERY}" \
  || fail "unexpected /query scenario_id: ${QUERY}"
body_contains '"answer"' "${QUERY}" || fail "/query missing answer: ${QUERY}"
body_contains 'FakeLLMClient' "${QUERY}" \
  || fail "/query answer does not look like FakeLLMClient output (is api.llm.backend=fake?): ${QUERY}"
log "PASS POST /query (fake LLM)"

log "All Kind deployment verification checks passed."
