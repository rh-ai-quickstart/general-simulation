# =============================================================================
# General Simulation & Impact-Reasoning Platform — Makefile
# =============================================================================
#
# Primary deploy (umbrella = one Helm release):
#   cp deploy/helm/values-secrets.yaml.example deploy/helm/values-secrets.yaml  # first time
#   make build
#   make deploy
#
# Secrets live in deploy/helm/values-secrets.yaml (gitignored). Helm validates required
# values via templates/_helpers.tpl.
#
# Enable LLM providers via global.models.<key>.enabled in deploy/helm/values.yaml.
# Set llm-service.enabled: true for in-cluster vLLM (requires hf_token in secrets).
#
# Image registry/tag: edit deploy/helm/values.yaml (global.registry, global.imageTag, …)
# or override on the command line (REGISTRY=/TAG=/APP_IMAGE_NAME= → helm --set).
# =============================================================================

# ── Configurable variables ────────────────────────────────────────────────────
REGISTRY            ?= quay.io/rh-ai-quickstart
NAMESPACE           ?= general-simulation
TAG                 ?= latest
APP_IMAGE_NAME      ?= general-sim-api
POSTGRES_IMAGE_NAME ?= general-sim-postgres
DEPLOY_TIMEOUT      ?= 25m
CHART_REPO_URL      ?= https://rh-ai-quickstart.github.io/general-simulation
LLM_SERVICE_CHART_REPO ?= https://rh-ai-quickstart.github.io/ai-architecture-charts
LLAMA_STACK_VERSION    ?= 0.8.5

# ── Derived image references ──────────────────────────────────────────────────
IMG_POSTGRES := $(REGISTRY)/$(POSTGRES_IMAGE_NAME):$(TAG)
IMG_APP      := $(REGISTRY)/$(APP_IMAGE_NAME):$(TAG)

# ── Helm chart paths ──────────────────────────────────────────────────────────
CHART_UMBRELLA       := deploy/helm
CHART_VALUES_SECRETS := deploy/helm/values-secrets.yaml

# Common flags passed to every helm command
HELM_RELEASE_NAME ?= general-simulation
HELM_COMMON := --namespace $(NAMESPACE) --create-namespace

# Optional helm --set overrides when image vars are passed on the make command line.
_helm_image_set :=
ifneq ($(filter command line,$(origin REGISTRY)),)
  _helm_image_set += --set global.registry=$(REGISTRY)
endif
ifneq ($(filter command line,$(origin TAG)),)
  _helm_image_set += --set global.imageTag=$(TAG)
endif
ifneq ($(filter command line,$(origin APP_IMAGE_NAME)),)
  _helm_image_set += --set global.images.app=$(APP_IMAGE_NAME)
endif
ifneq ($(filter command line,$(origin POSTGRES_IMAGE_NAME)),)
  _helm_image_set += --set global.images.postgres=$(POSTGRES_IMAGE_NAME)
endif

# Stack model ids (providerKey/model.id)
LOCAL_MODEL_KEY  ?= deepseek-r1-distill-qwen-1-5b
LOCAL_MODEL_ID   ?= deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B

# ── Phony declarations ────────────────────────────────────────────────────────
.PHONY: all help \
        build build-postgres build-app \
        deploy deploy-umbrella neo4j-connect \
        package-chart \
        undeploy status lint-charts \
        _guard-values-secrets \
        _guard-oc _guard-helm _guard-podman \
        _remove-orphan-neo4j-resources _remove-openshift-routes

# ── Default target ────────────────────────────────────────────────────────────
all: help

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@printf "\nGeneral Simulation Platform — available targets:\n"
	@printf "  %-40s %s\n" "build" "Build and push all container images"
	@printf "  %-40s %s\n" "deploy" "Umbrella install (requires deploy/helm/values-secrets.yaml)"
	@printf "  %-40s %s\n" "  Edit deploy/helm/values.yaml" "  Enable models via global.models.<key>.enabled"
	@printf "  %-40s %s\n" "neo4j-connect" "Port-forward Neo4j Browser + Bolt"
	@printf "  %-40s %s\n" "package-chart" "Package umbrella chart into dist/"
	@printf "  %-40s %s\n" "undeploy" "Uninstall Helm releases"
	@printf "  %-40s %s\n" "status" "helm list + oc get pods"
	@printf "  %-40s %s\n" "lint-charts" "helm lint"
	@printf "  %-40s %s\n" "smoke-test" "Seed UK demo + POST /query (auto cluster when deployed)"
	@printf "\nVariables:\n"
	@printf "  %-18s %s\n" "REGISTRY"         "$(REGISTRY)"
	@printf "  %-18s %s\n" "APP_IMAGE_NAME"   "$(APP_IMAGE_NAME)"
	@printf "  %-18s %s\n" "NAMESPACE"        "$(NAMESPACE)"
	@printf "  %-18s %s\n" "TAG"              "$(TAG)"
	@printf "  %-18s %s\n" "DEPLOY_TIMEOUT"   "$(DEPLOY_TIMEOUT)"
	@printf "  %-18s %s\n" "CHART_REPO_URL"   "$(CHART_REPO_URL)"
	@printf "\nSecrets: copy deploy/helm/values-secrets.yaml.example → deploy/helm/values-secrets.yaml\n"
	@printf "\n"

# ── Guards ────────────────────────────────────────────────────────────────────
_guard-values-secrets:
	@test -f "$(CHART_VALUES_SECRETS)" || { \
	  printf "ERROR: %s is required.\n" "$(CHART_VALUES_SECRETS)"; \
	  printf "  cp deploy/helm/values-secrets.yaml.example deploy/helm/values-secrets.yaml\n"; \
	  exit 1; \
	}

_guard-oc:
	@command -v oc >/dev/null 2>&1 || \
	  { echo "ERROR: 'oc' CLI not found. Install the OpenShift CLI and run 'oc login'."; exit 1; }

_guard-helm:
	@command -v helm >/dev/null 2>&1 || \
	  { echo "ERROR: 'helm' CLI not found. Install Helm 3+ from https://helm.sh/docs/intro/install/"; exit 1; }

_guard-podman:
	@command -v podman >/dev/null 2>&1 || \
	  { echo "ERROR: 'podman' not found. Install Podman or substitute 'docker' by setting PODMAN=docker."; exit 1; }

# ── Container image builds ────────────────────────────────────────────────────
build: _guard-podman build-postgres build-app
	@echo "==> All images built and pushed to $(REGISTRY)."

build-postgres: _guard-podman
	@echo "==> Building Postgres image: $(IMG_POSTGRES)"
	podman build \
	  --platform=linux/amd64 \
	  -f deploy/container_files/postgres/Containerfile \
	  -t $(IMG_POSTGRES) \
	  deploy/container_files/postgres
	podman push $(IMG_POSTGRES)

build-app: _guard-podman
	@echo "==> Building FastAPI app image: $(IMG_APP)"
	podman build \
	  --platform=linux/amd64 \
	  -f deploy/container_files/api/Containerfile \
	  -t $(IMG_APP) \
	  .
	podman push $(IMG_APP)

# ── OpenShift cleanup (pre/post Helm) ─────────────────────────────────────────
# bindings without Helm ownership metadata — delete those so umbrella install can
# manage them (templates/neo4j/).
_remove-orphan-neo4j-resources: _guard-oc
	@echo "==> Checking for pre-Helm Neo4j OpenShift resources..."
	@rel="$(HELM_RELEASE_NAME)"; \
	for kind_name in "secret neo4j-auth" "serviceaccount neo4j-sa"; do \
	  set -- $$kind_name; kind=$$1; name=$$2; \
	  if oc get $$kind $$name -n $(NAMESPACE) >/dev/null 2>&1; then \
	    owner=$$(oc get $$kind $$name -n $(NAMESPACE) \
	      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null); \
	    if [ "$$owner" != "$$rel" ]; then \
	      echo "    Removing orphan $$kind/$$name (not owned by Helm release $$rel)..."; \
	      oc delete $$kind $$name -n $(NAMESPACE) --ignore-not-found; \
	    fi; \
	  fi; \
	done; \
	crb="$(NAMESPACE)-neo4j-anyuid"; \
	if oc get clusterrolebinding $$crb >/dev/null 2>&1; then \
	  owner=$$(oc get clusterrolebinding $$crb \
	    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null); \
	  if [ "$$owner" != "$$rel" ]; then \
	    echo "    Removing orphan clusterrolebinding/$$crb..."; \
	    oc delete clusterrolebinding $$crb --ignore-not-found; \
	  fi; \
	fi

# OpenShift Routes — chart uses general-sim-admin; older/manual installs used admin-console.
_remove-openshift-routes: _guard-oc
	@echo "==> Removing OpenShift Routes in namespace $(NAMESPACE)..."
	@ns="$(NAMESPACE)"; \
	delete_if_present() { \
	  name="$$1"; \
	  [ -z "$$name" ] && return 0; \
	  if oc get route "$$name" -n "$$ns" >/dev/null 2>&1; then \
	    echo "    Deleting route/$$name..."; \
	    oc delete route "$$name" -n "$$ns" --ignore-not-found; \
	  fi; \
	}; \
	for name in admin-console general-sim-admin general-sim-api neo4j; do \
	  delete_if_present "$$name"; \
	done; \
	oc delete route -l app.kubernetes.io/component=admin -n "$$ns" --ignore-not-found 2>/dev/null || true; \
	for r in $$(oc get route -n "$$ns" -o go-template='{{range .items}}{{if or (eq .spec.to.name "general-sim-api") (eq .spec.to.name "neo4j") (eq .spec.path "/admin")}}{{.metadata.name}}{{" "}}{{end}}{{end}}' 2>/dev/null); do \
	  delete_if_present "$$r"; \
	done

# ── Primary deploy (umbrella) ─────────────────────────────────────────────────

## One-command install: Postgres + Neo4j + bootstrap + Llama Stack + API + ingestion
## (+ llm-service when llm-service.enabled in deploy/helm/values.yaml).
deploy: deploy-umbrella

deploy-umbrella: _guard-values-secrets \
                 _guard-oc _guard-helm _remove-orphan-neo4j-resources
	@echo "==> Updating umbrella chart dependencies..."
	helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
	helm repo update neo4j
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm dependency update $(CHART_UMBRELLA)
	@echo "==> Deploying umbrella..."
	helm upgrade --install $(HELM_RELEASE_NAME) $(CHART_UMBRELLA) \
	  $(HELM_COMMON) \
	  -f $(CHART_VALUES_SECRETS) \
	  $(_helm_image_set) \
	  --wait --timeout $(DEPLOY_TIMEOUT)
	@printf "\n==> Deployment complete.\n"
	@printf "    API (same-NS):  http://general-sim-api:8000\n"
	@printf "    Llama Stack:    http://llamastack:8321/v1\n"
	@printf "    Smoke test:\n"
	@printf "      ROUTE=\$$(oc get route general-sim-api -n $(NAMESPACE)"
	@printf " -o jsonpath='{.spec.host}')\n"
	@printf "      curl -s https://\$$ROUTE/health | jq .\n"
	@printf "      make smoke-test   # auto-detects cluster vs local seeding\n"
	@printf "    Neo4j Browser: make neo4j-connect NAMESPACE=$(NAMESPACE)\n\n"

neo4j-connect: _guard-oc
	@printf "\n==> Starting Neo4j port-forward (ctrl-c to stop)...\n"
	@printf "    Browser UI: http://localhost:7474/browser/\n"
	@printf "    Connect with: bolt://localhost:7687\n"
	@printf "    Username: neo4j\n\n"
	oc port-forward svc/neo4j 7474:7474 7687:7687 -n $(NAMESPACE)

# ── Package / undeploy / status / lint ────────────────────────────────────────

package-chart: _guard-helm
	@echo "==> Packaging $(CHART_UMBRELLA) ..."
	helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
	helm repo update neo4j
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm dependency update $(CHART_UMBRELLA)
	helm lint $(CHART_UMBRELLA)
	mkdir -p dist
	helm package $(CHART_UMBRELLA) -d dist/
	@echo "==> Packaged charts in dist/. Publish URL: $(CHART_REPO_URL)"

undeploy: _guard-helm _guard-oc _remove-openshift-routes
	@echo "==> Removing Helm releases from namespace $(NAMESPACE)..."
	helm uninstall $(HELM_RELEASE_NAME) --namespace $(NAMESPACE) 2>/dev/null || true
	helm uninstall ingestion --namespace $(NAMESPACE) 2>/dev/null || true
	helm uninstall api       --namespace $(NAMESPACE) 2>/dev/null || true
	helm uninstall llm-service --namespace $(NAMESPACE) 2>/dev/null || true
	helm uninstall vllm      --namespace $(NAMESPACE) 2>/dev/null || true
	helm uninstall bootstrap --namespace $(NAMESPACE) 2>/dev/null || true
	helm uninstall neo4j     --namespace $(NAMESPACE) 2>/dev/null || true
	helm uninstall postgres  --namespace $(NAMESPACE) 2>/dev/null || true
	@echo "==> Removing Neo4j anyuid SCC binding + ServiceAccount..."
	@oc delete clusterrolebinding $(NAMESPACE)-neo4j-anyuid --ignore-not-found >/dev/null
	@oc delete clusterrolebinding $(NAMESPACE)-postgres-anyuid --ignore-not-found >/dev/null
	@oc delete serviceaccount neo4j-sa postgres-sa -n $(NAMESPACE) --ignore-not-found >/dev/null
	@oc delete secret neo4j-auth pgvector -n $(NAMESPACE) --ignore-not-found >/dev/null
	@echo "    Done. PVCs are NOT deleted automatically — remove manually if needed:"
	@echo "      oc delete pvc -n $(NAMESPACE) --all"

status: _guard-helm _guard-oc
	@echo "==> Helm releases in namespace $(NAMESPACE):"
	@helm list --namespace $(NAMESPACE)
	@echo ""
	@echo "==> Pod status:"
	@oc get pods -n $(NAMESPACE)

lint-charts: _guard-helm
	helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
	helm repo update neo4j
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm dependency update $(CHART_UMBRELLA)
	helm lint $(CHART_UMBRELLA)
	@echo "==> Chart passed lint."

smoke-test:
	@chmod +x scripts/smoke-uk-closure.sh
	./scripts/smoke-uk-closure.sh
