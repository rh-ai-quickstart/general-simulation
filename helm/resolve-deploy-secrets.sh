#!/usr/bin/env bash
# Resolve deploy secrets: make/env var overrides values-secrets.yaml.
# Priority: 1) non-empty env/make variable  2) helm/values-secrets.yaml
#
# Required secrets are derived from helm/values.yaml:
#   - global.postgres.password, global.neo4j.password (always)
#   - global.models.<key>.apiToken for each enabled model with a remote url
#   - llm-service.secret.hf_token when llm-service.enabled is true
#
# Exports for the caller (deploy recipe):
#   SECRET_HELM_ARGS — non-empty --set-string flags only for explicit overrides
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read_secret() { "$SCRIPT_DIR/read-secret.sh" "$@"; }

CHART_VALUES="${CHART_VALUES:-$SCRIPT_DIR/values.yaml}"
CHART_VALUES_SECRETS="${CHART_VALUES_SECRETS:-$SCRIPT_DIR/values-secrets.yaml}"

is_placeholder() {
  case "$1" in
    ""|CHANGE_ME|changeme|CHANGEME) return 0 ;;
    *) return 1 ;;
  esac
}

is_enabled() {
  case "$(read_secret "$CHART_VALUES" "$1")" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

resolve() {
  local env_val="$1" yaml_path="$2"
  if [ -n "$env_val" ]; then
    printf '%s' "$env_val"
    return
  fi
  if [ -f "${CHART_VALUES_SECRETS}" ]; then
    read_secret "$CHART_VALUES_SECRETS" "$yaml_path"
  fi
}

require_secret() {
  local label="$1" effective="$2"
  if is_placeholder "$effective"; then
    printf 'ERROR: %s is required (make/env var, or %s).\n' "$label" "$CHART_VALUES_SECRETS" >&2
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

# Enabled remote models need apiToken (skip in-cluster providers without url).
for model_key in openai external-model nomic deepseek-r1-distill-qwen-1-5b; do
  if ! is_enabled "global.models.${model_key}.enabled"; then
    continue
  fi
  url="$(read_secret "$CHART_VALUES" "global.models.${model_key}.url")"
  if [ -z "$url" ]; then
    continue
  fi
  token_path="global.models.${model_key}.apiToken"
  env_var=""
  case "$model_key" in
    openai) env_var="${OPENAI_API_KEY:-}" ;;
    external-model) env_var="${MAAS_API_TOKEN:-}" ;;
    nomic) env_var="${MAAS_API_TOKEN:-}" ;;
  esac
  effective="$(resolve "$env_var" "$token_path")"
  require_secret "${model_key} apiToken (${token_path})" "$effective"
  if [ -n "$env_var" ]; then
    append_set "$token_path" "$env_var"
  fi
done

if is_enabled llm-service.enabled; then
  HF_EFFECTIVE="$(resolve "${HF_TOKEN:-}" llm-service.secret.hf_token)"
  require_secret "HF_TOKEN (llm-service.secret.hf_token)" "$HF_EFFECTIVE"
  [ -n "${HF_TOKEN:-}" ] && append_set llm-service.secret.hf_token "$HF_TOKEN"
fi

export SECRET_HELM_ARGS
