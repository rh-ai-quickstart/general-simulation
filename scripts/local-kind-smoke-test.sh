#!/usr/bin/env bash
# Local Kind Helm smoke — same path as .github/workflows/kind-helm-smoke.yml
#
# Creates a Kind cluster (Podman) with a localhost:5001 registry, builds and
# pushes images, installs with deploy/helm/values-kind.yaml, then runs
# scripts/ci/kind-verify-deployment.sh.
#
# Usage:
#   ./scripts/local-kind-smoke-test.sh
#   make local-kind-smoke-test
#
# Options:
#   --recreate     Delete the Kind cluster + registry and start clean
#   --skip-build   Reuse images already in localhost:5001
#   --cleanup      Delete the Kind cluster + registry after a successful run
#   -h, --help     Show this help
#
# Environment:
#   USE_PODMAN=1          Default. Set 0 to use Docker if it is on PATH.
#   REGISTRY              Default localhost:5001
#   NAMESPACE             Default general-simulation
#   HELM_RELEASE          Default general-simulation
#   MIN_PODMAN_MEMORY_MIB Default 8192. Neo4j chart min is 2Gi; see make kind-preflight.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

REGISTRY="${REGISTRY:-localhost:5001}"
NAMESPACE="${NAMESPACE:-general-simulation}"
HELM_RELEASE="${HELM_RELEASE:-general-simulation}"
USE_PODMAN="${USE_PODMAN:-1}"
KIND_CLUSTER="${KIND_CLUSTER:-kind}"
REG_NAME="${REG_NAME:-kind-registry}"

RECREATE=0
SKIP_BUILD=0
CLEANUP=0

log() { echo ">>> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,24p' "$0" | sed 's/^# //'
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not on PATH"
}

container_cli() {
  if [[ "${USE_PODMAN}" == "1" ]]; then
    echo podman
  elif command -v docker >/dev/null 2>&1; then
    echo docker
  else
    echo podman
  fi
}

kind_cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"
}

delete_kind_stack() {
  local cli
  cli="$(container_cli)"
  log "Deleting Kind cluster '${KIND_CLUSTER}' and registry '${REG_NAME}'"
  kind delete cluster --name "${KIND_CLUSTER}" 2>/dev/null || true
  "${cli}" rm -f "${REG_NAME}" >/dev/null 2>&1 || true
}

dump_cluster() {
  set +e
  echo "=== kubectl get deploy,sts,svc,pvc,job,pods -n ${NAMESPACE} ==="
  kubectl get deploy,sts,svc,pvc,job,pods -n "${NAMESPACE}" -o wide
  echo "=== kubectl get events -n ${NAMESPACE} (last 40) ==="
  kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | tail -40
  echo "=== helm status ==="
  helm status "${HELM_RELEASE}" -n "${NAMESPACE}" || true
  set -e
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate) RECREATE=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --cleanup) CLEANUP=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1 (see --help)"
      ;;
  esac
  shift
done

need_cmd kind
need_cmd kubectl
need_cmd helm
need_cmd make
if [[ "${USE_PODMAN}" == "1" ]]; then
  need_cmd podman
fi

log "Running Kind preflight (Podman VM / node RAM)"
USE_PODMAN="${USE_PODMAN}" make kind-preflight

if [[ "${RECREATE}" == "1" ]]; then
  delete_kind_stack
fi

if kind_cluster_exists; then
  log "Kind cluster '${KIND_CLUSTER}' already exists — skipping create (pass --recreate for a clean cluster)"
  USE_PODMAN="${USE_PODMAN}" make kind-preflight
else
  log "Creating Kind cluster with local registry (USE_PODMAN=${USE_PODMAN})"
  USE_PODMAN="${USE_PODMAN}" bash "${ROOT}/scripts/ci/kind-with-registry.sh"
  USE_PODMAN="${USE_PODMAN}" make kind-preflight
fi

if [[ "${SKIP_BUILD}" == "1" ]]; then
  log "Skipping image build (--skip-build)"
else
  log "Building images for ${REGISTRY}"
  make kind-build-images REGISTRY="${REGISTRY}"
  log "Pushing images to ${REGISTRY}"
  make kind-push-images REGISTRY="${REGISTRY}" PUSH_EXTRA_ARGS=--tls-verify=false
fi

log "Helm install (values-kind.yaml, registry=${REGISTRY})"
if ! make helm-install-kind \
  NAMESPACE="${NAMESPACE}" \
  HELM_RELEASE_NAME="${HELM_RELEASE}" \
  REGISTRY="${REGISTRY}"; then
  dump_cluster
  fail "helm-install-kind failed (cluster dump above)"
fi

log "Running Kind verify (health + seed + /query)"
make kind-verify NAMESPACE="${NAMESPACE}" HELM_RELEASE_NAME="${HELM_RELEASE}"

if [[ "${CLEANUP}" == "1" ]]; then
  delete_kind_stack
  log "Cleanup complete"
else
  log "Kind smoke passed. Cluster left running (pass --cleanup to delete it)."
  log "  kubectl get pods -n ${NAMESPACE}"
  log "  make kind-undeploy NAMESPACE=${NAMESPACE} HELM_RELEASE_NAME=${HELM_RELEASE}"
fi
