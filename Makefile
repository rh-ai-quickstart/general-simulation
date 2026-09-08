# =============================================================================
# General Simulation & Impact-Reasoning Platform — Makefile
# =============================================================================
#
# Primary deploy (umbrella = one Helm release):
#   make build
#   make deploy   # secrets from helm/values-secrets.yaml if present
#   make deploy PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> MAAS_API_TOKEN=<tok>
#
# Enable LLM providers via global.models.<key>.enabled in helm/values.yaml.
# Set llm-service.enabled: true for in-cluster vLLM (requires HF_TOKEN).
#
# Per-component: deploy-neo4j, deploy-llm-service (standalone debug only)
#
# Image registry/tag: edit helm/values.yaml (global.registry, global.imageTag, …).
# make build* reads those defaults; make deploy uses values.yaml unless you pass
# REGISTRY=/TAG=/APP_IMAGE_NAME= on the command line to override via --set.
# =============================================================================

# ── Configurable variables ────────────────────────────────────────────────────
# Image coordinates default from helm/values.yaml; override on the command line
# for build (make build-app REGISTRY=...) or deploy (--set when REGISTRY/TAG set).
_val_registry  := $(shell ./helm/read-secret.sh helm/values.yaml global.registry 2>/dev/null)
_val_tag       := $(shell ./helm/read-secret.sh helm/values.yaml global.imageTag 2>/dev/null)
_val_app       := $(shell ./helm/read-secret.sh helm/values.yaml global.images.app 2>/dev/null)
_val_postgres  := $(shell ./helm/read-secret.sh helm/values.yaml global.images.postgres 2>/dev/null)
REGISTRY         ?= $(or $(_val_registry),quay.io/rh-ai-quickstart)
NAMESPACE        ?= general-simulation
TAG              ?= $(or $(_val_tag),latest)
APP_IMAGE_NAME   ?= $(or $(_val_app),general-sim-api)
POSTGRES_IMAGE_NAME ?= $(or $(_val_postgres),general-sim-postgres)
PG_PASSWORD      ?=
NEO4J_PASSWORD   ?=
OPENAI_API_KEY   ?=
MAAS_API_TOKEN   ?=
HF_TOKEN         ?=
CHART_REPO_URL   ?= https://rh-ai-quickstart.github.io/general-simulation
LLM_SERVICE_CHART_REPO ?= https://rh-ai-quickstart.github.io/ai-architecture-charts
LLM_SERVICE_VERSION    ?= 0.5.9
LLAMA_STACK_VERSION    ?= 0.8.5

# ── Derived image references ──────────────────────────────────────────────────
IMG_POSTGRES := $(REGISTRY)/$(POSTGRES_IMAGE_NAME):$(TAG)
IMG_APP      := $(REGISTRY)/$(APP_IMAGE_NAME):$(TAG)

# ── Helm chart paths ──────────────────────────────────────────────────────────
CHART_UMBRELLA  := helm
CHART_NEO4J     := helm/neo4j
CHART_VALUES    := helm/values.yaml
CHART_VALUES_SECRETS := helm/values-secrets.yaml
LLM_SERVICE_STANDALONE_VALUES := helm/llm-service-standalone.yaml

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
        deploy deploy-umbrella \
        deploy-neo4j deploy-llm-service neo4j-connect \
        package-chart \
        undeploy status lint-charts \
        _guard-deploy-secrets _guard-pg-password _guard-neo4j-password \
        _guard-oc _guard-helm _guard-podman \
        _remove-orphan-neo4j-resources _remove-openshift-routes

# ── Default target ────────────────────────────────────────────────────────────
all: help

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@printf "\nGeneral Simulation Platform — available targets:\n"
	@printf "  %-40s %s\n" "build" "Build and push all container images"
	@printf "  %-40s %s\n" "deploy" "Umbrella install (secrets: env, make vars, or helm/values-secrets.yaml)"
	@printf "  %-40s %s\n" "  Edit helm/values.yaml" "  Enable models via global.models.<key>.enabled"
	@printf "  %-40s %s\n" "deploy-neo4j / deploy-llm-service" "Standalone debug installs only"
	@printf "  %-40s %s\n" "neo4j-connect" "Port-forward Neo4j Browser + Bolt"
	@printf "  %-40s %s\n" "package-chart" "Package umbrella chart into dist/"
	@printf "  %-40s %s\n" "undeploy" "Uninstall Helm releases"
	@printf "  %-40s %s\n" "status" "helm list + oc get pods"
	@printf "  %-40s %s\n" "lint-charts" "helm lint"
	@printf "  %-40s %s\n" "smoke-test" "Seed UK demo + POST /query (auto cluster when deployed)"
	@printf "\nVariables:\n"
	@printf "  %-18s %s\n" "REGISTRY"         "$(REGISTRY) (from values.yaml; override on CLI)"
	@printf "  %-18s %s\n" "APP_IMAGE_NAME"   "$(APP_IMAGE_NAME)"
	@printf "  %-18s %s\n" "NAMESPACE"        "$(NAMESPACE)"
	@printf "  %-18s %s\n" "TAG"              "$(TAG)"
	@printf "  %-18s %s\n" "PG_PASSWORD"      "(or global.postgres.password in values-secrets.yaml)"
	@printf "  %-18s %s\n" "NEO4J_PASSWORD"   "(or global.neo4j.password in values-secrets.yaml)"
	@printf "  %-18s %s\n" "MAAS_API_TOKEN"   "(enabled remote models; or values-secrets.yaml)"
	@printf "  %-18s %s\n" "OPENAI_API_KEY"   "(when global.models.openai.enabled; or values-secrets.yaml)"
	@printf "  %-18s %s\n" "HF_TOKEN"         "(when llm-service.enabled; or values-secrets.yaml)"
	@printf "  %-18s %s\n" "CHART_REPO_URL"   "$(CHART_REPO_URL)"
	@printf "\n"

# ── Guards ────────────────────────────────────────────────────────────────────
# Secret priority: make/env var (also passed via --set) > helm/values-secrets.yaml
_guard-pg-password:
	@effective="$(PG_PASSWORD)"; \
	if [ -z "$$effective" ] && [ -f "$(CHART_VALUES_SECRETS)" ]; then \
	  effective="$$(./helm/read-secret.sh "$(CHART_VALUES_SECRETS)" global.postgres.password)"; \
	fi; \
	case "$$effective" in ""|CHANGE_ME) \
	  printf "ERROR: PG_PASSWORD is required (make/env, or global.postgres.password in %s).\n" "$(CHART_VALUES_SECRETS)"; exit 1 ;; \
	esac

_guard-neo4j-password:
	@effective="$(NEO4J_PASSWORD)"; \
	if [ -z "$$effective" ] && [ -f "$(CHART_VALUES_SECRETS)" ]; then \
	  effective="$$(./helm/read-secret.sh "$(CHART_VALUES_SECRETS)" global.neo4j.password)"; \
	fi; \
	case "$$effective" in ""|CHANGE_ME) \
	  printf "ERROR: NEO4J_PASSWORD is required (make/env, or global.neo4j.password in %s).\n" "$(CHART_VALUES_SECRETS)"; exit 1 ;; \
	esac

_guard-deploy-secrets:
	@CHART_VALUES="$(CHART_VALUES)" \
	 CHART_VALUES_SECRETS="$(CHART_VALUES_SECRETS)" \
	 PG_PASSWORD="$(PG_PASSWORD)" \
	 NEO4J_PASSWORD="$(NEO4J_PASSWORD)" \
	 MAAS_API_TOKEN="$(MAAS_API_TOKEN)" \
	 OPENAI_API_KEY="$(OPENAI_API_KEY)" \
	 HF_TOKEN="$(HF_TOKEN)" \
	 . ./helm/resolve-deploy-secrets.sh

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
	  -f deploy/postgres/Containerfile \
	  -t $(IMG_POSTGRES) \
	  deploy/postgres
	podman push $(IMG_POSTGRES)

build-app: _guard-podman
	@echo "==> Building FastAPI app image: $(IMG_APP)"
	podman build \
	  --platform=linux/amd64 \
	  -f deploy/app/Containerfile \
	  -t $(IMG_APP) \
	  .
	podman push $(IMG_APP)

# ── Namespace bootstrap ───────────────────────────────────────────────────────
_deploy-namespace: _guard-oc
	oc apply -f deploy/openshift/namespace.yaml

# Pre-Helm deploy (make deploy / oc create) left neo4j-auth, neo4j-sa, and SCC
# bindings without Helm ownership metadata — delete those so umbrella install can manage them.
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
## (+ llm-service when llm-service.enabled in helm/values.yaml).
deploy: deploy-umbrella

deploy-umbrella: _guard-deploy-secrets \
                 _guard-oc _guard-helm _deploy-namespace _remove-orphan-neo4j-resources
	@echo "==> Updating umbrella chart dependencies..."
	helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
	helm repo update neo4j
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm dependency update $(CHART_UMBRELLA)
	@echo "==> Deploying umbrella..."
	@CHART_VALUES="$(CHART_VALUES)" \
	 CHART_VALUES_SECRETS="$(CHART_VALUES_SECRETS)" \
	 PG_PASSWORD="$(PG_PASSWORD)" \
	 NEO4J_PASSWORD="$(NEO4J_PASSWORD)" \
	 MAAS_API_TOKEN="$(MAAS_API_TOKEN)" \
	 OPENAI_API_KEY="$(OPENAI_API_KEY)" \
	 HF_TOKEN="$(HF_TOKEN)" \
	 . ./helm/resolve-deploy-secrets.sh; \
	helm_args=""; \
	if [ -f "$(CHART_VALUES_SECRETS)" ]; then \
	  helm_args="$$helm_args -f $(CHART_VALUES_SECRETS)"; \
	fi; \
	llm_svc_enabled="$$(./helm/read-secret.sh "$(CHART_VALUES)" llm-service.enabled)"; \
	deploy_timeout=15m; \
	case "$$llm_svc_enabled" in true|True|TRUE|yes|Yes|YES|1) deploy_timeout=25m ;; esac; \
	helm upgrade --install $(HELM_RELEASE_NAME) $(CHART_UMBRELLA) \
	  $(HELM_COMMON) \
	  $$helm_args \
	  $(_helm_image_set) \
	  $$SECRET_HELM_ARGS \
	  --wait --timeout $$deploy_timeout
	@printf "\n==> Deployment complete.\n"
	@printf "    API (same-NS):  http://general-sim-api:8000\n"
	@printf "    Llama Stack:    http://llamastack:8321/v1\n"
	@printf "    Smoke test:\n"
	@printf "      ROUTE=\$$(oc get route general-sim-api -n $(NAMESPACE)"
	@printf " -o jsonpath='{.spec.host}')\n"
	@printf "      curl -s https://\$$ROUTE/health | jq .\n"
	@printf "      make smoke-test   # auto-detects cluster vs local seeding\n"
	@printf "    Neo4j Browser: make neo4j-connect NAMESPACE=$(NAMESPACE)\n\n"

# ── Advanced: standalone debug targets ────────────────────────────────────────

## Neo4j — official chart; OpenShift needs neo4j-sa + anyuid SCC (UID 7474).
deploy-neo4j: _guard-neo4j-password _guard-oc _guard-helm _deploy-namespace
	@echo "==> Creating neo4j-sa + anyuid SCC binding..."
	oc apply -f deploy/openshift/neo4j/serviceaccount.yaml -n $(NAMESPACE)
	@sed "s/__NAMESPACE__/$(NAMESPACE)/g" deploy/openshift/neo4j/scc-binding.yaml | oc apply -f -
	@echo "==> Adding/updating Neo4j Helm repo..."
	helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
	helm repo update neo4j
	$(eval OCP_DOMAIN   := $(shell oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null))
	$(eval NEO4J_ROUTE_HOST := neo4j-$(NAMESPACE).$(OCP_DOMAIN))
	@echo "==> Creating neo4j-auth secret..."
	@oc delete secret neo4j-auth -n $(NAMESPACE) --ignore-not-found >/dev/null
	@oc create secret generic neo4j-auth \
	  --from-literal=NEO4J_AUTH="neo4j/$(NEO4J_PASSWORD)" \
	  -n $(NAMESPACE)
	helm upgrade --install neo4j neo4j/neo4j \
	  --version 2026.5.0 \
	  $(HELM_COMMON) \
	  -f $(CHART_NEO4J)/values.yaml \
	  --set "config.server\.default_advertised_address=$(NEO4J_ROUTE_HOST)" \
	  --wait --timeout 10m
	@oc create route edge neo4j \
	  --service=neo4j --port=tcp-http \
	  --insecure-policy=Redirect \
	  -n $(NAMESPACE) 2>/dev/null || true
	@printf "\n    Neo4j deployed. Browser: https://$(NEO4J_ROUTE_HOST)/browser/\n\n"

neo4j-connect: _guard-oc
	@printf "\n==> Starting Neo4j port-forward (ctrl-c to stop)...\n"
	@printf "    Browser UI: http://localhost:7474/browser/\n"
	@printf "    Connect with: bolt://localhost:7687\n"
	@printf "    Username: neo4j\n\n"
	oc port-forward svc/neo4j 7474:7474 7687:7687 -n $(NAMESPACE)

deploy-llm-service: _guard-helm _guard-oc _deploy-namespace
	@test -n "$(HF_TOKEN)" || \
	  { printf "ERROR: HF_TOKEN is required.\n"; exit 1; }
	@echo "==> Deploying llm-service only (set llm-service.enabled: true in helm/values.yaml for umbrella)..."
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm upgrade --install llm-service ai-architecture-charts/llm-service \
	  --version $(LLM_SERVICE_VERSION) \
	  $(HELM_COMMON) \
	  -f $(LLM_SERVICE_STANDALONE_VALUES) \
	  --set-string secret.hf_token='$(HF_TOKEN)' \
	  --wait --timeout 20m
	@printf "    In-cluster vLLM via llm-service (enable llm-service in helm/values.yaml for umbrella).\n\n"

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
