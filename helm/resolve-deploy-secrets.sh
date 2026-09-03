#!/usr/bin/env bash
# Resolve deploy secrets: make/env var overrides values-secrets.yaml.
# Priority: 1) non-empty env/make variable  2) helm/values-secrets.yaml
#
# Required environment:
#   LLM_MODE, CHART_VALUES_SECRETS
#   PG_PASSWORD, NEO4J_PASSWORD, MAAS_API_TOKEN, OPENAI_API_KEY, HF_TOKEN
#
# Exports for the caller (deploy recipe):
#   SECRET_HELM_ARGS — non-empty --set-string flags only for explicit overrides
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read_secret() { "$SCRIPT_DIR/read-secret.sh" "$@"; }

is_placeholder() {
  case "$1" in
    ""|CHANGE_ME|changeme|CHANGEME) return 0 ;;
    *) return 1 ;;
  esac
}

resolve() {
  local env_val="$1" yaml_path="$2"
  if [ -n "$env_val" ]; then
    printf '%s' "$env_val"
    return
  fi
  if [ -f "${CHART_VALUES_SECRETS:-}" ]; then
    read_secret "$CHART_VALUES_SECRETS" "$yaml_path"
  fi
}

require_secret() {
  local label="$1" effective="$2"
  if is_placeholder "$effective"; then
    printf 'ERROR: %s is required (make/env var, or %s).\n' "$label" "${CHART_VALUES_SECRETS:-helm/values-secrets.yaml}" >&2
    exit 1
  fi
}

append_set() {
  local helm_key="$1" value="$2"
  local esc="${value//\'/\'\"\'\"\'}"
  SECRET_HELM_ARGS="${SECRET_HELM_ARGS} --set-string ${helm_key}='${esc}'"
}

PG_EFFECTIVE="$(resolve "${PG_PASSWORD:-}" global.postgres.password)"
NEO4J_EFFECTIVE="$(resolve "${NEO4J_PASSWORD:-}" global.neo4j.password)"

require_secret "PG_PASSWORD (global.postgres.password)" "$PG_EFFECTIVE"
require_secret "NEO4J_PASSWORD (global.neo4j.password)" "$NEO4J_EFFECTIVE"

SECRET_HELM_ARGS=""
[ -n "${PG_PASSWORD:-}" ] && append_set global.postgres.password "$PG_PASSWORD"
[ -n "${NEO4J_PASSWORD:-}" ] && append_set global.neo4j.password "$NEO4J_PASSWORD"

case "${LLM_MODE:-maas}" in
  maas)
    MAAS_EFFECTIVE="$(resolve "${MAAS_API_TOKEN:-}" global.models.external-model.apiToken)"
    require_secret "MAAS_API_TOKEN (global.models.external-model.apiToken)" "$MAAS_EFFECTIVE"
    [ -n "${MAAS_API_TOKEN:-}" ] && append_set global.models.external-model.apiToken "$MAAS_API_TOKEN"
    ;;
  openai)
    OPENAI_EFFECTIVE="$(resolve "${OPENAI_API_KEY:-}" global.models.openai.apiToken)"
    require_secret "OPENAI_API_KEY (global.models.openai.apiToken)" "$OPENAI_EFFECTIVE"
    [ -n "${OPENAI_API_KEY:-}" ] && append_set global.models.openai.apiToken "$OPENAI_API_KEY"
    ;;
  local)
    HF_EFFECTIVE="$(resolve "${HF_TOKEN:-}" llm-service.secret.hf_token)"
    require_secret "HF_TOKEN (llm-service.secret.hf_token)" "$HF_EFFECTIVE"
    [ -n "${HF_TOKEN:-}" ] && append_set llm-service.secret.hf_token "$HF_TOKEN"
    ;;
  *)
    printf "ERROR: LLM_MODE must be 'maas', 'openai', or 'local' (got '%s').\n" "${LLM_MODE:-}" >&2
    exit 1
    ;;
esac

export SECRET_HELM_ARGS
