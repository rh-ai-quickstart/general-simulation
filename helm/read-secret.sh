#!/usr/bin/env bash
# Read a dotted key from a Helm values YAML file (e.g. global.postgres.password).
# Prints the value or nothing. Requires ruby (macOS default) or yq.
set -euo pipefail

file="${1:?usage: read-secret.sh <file> <dot.path>}"
path="${2:?usage: read-secret.sh <file> <dot.path>}"

if [[ ! -f "$file" ]]; then
  exit 0
fi

if command -v yq >/dev/null 2>&1; then
  yq -r ".${path} // \"\"" "$file" 2>/dev/null || true
  exit 0
fi

if ! command -v ruby >/dev/null 2>&1; then
  echo "read-secret.sh: need yq or ruby to read ${file}" >&2
  exit 1
fi

ruby -ryaml -e '
  file, path = ARGV
  data = YAML.load_file(file) || {}
  val = path.split(".").reduce(data) { |h, k| h.is_a?(Hash) ? h[k] : nil }
  puts(val.nil? ? "" : val.to_s)
' "$file" "$path"
