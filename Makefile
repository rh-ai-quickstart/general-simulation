# =============================================================================
# General Simulation & Impact-Reasoning Platform — Makefile
# =============================================================================
#
# Primary deploy (umbrella = one Helm release):
#   make build
#   make deploy   # secrets from helm/values-secrets.yaml if present
#   make deploy PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> MAAS_API_TOKEN=<tok>
#   make deploy LLM_MODE=openai PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> OPENAI_API_KEY=<key>
#   make deploy LLM_MODE=local PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> HF_TOKEN=<tok>
#
# LLM_MODE=maas (default)  — Llama Stack → LiteMaaS (external-model)
# LLM_MODE=openai            — Llama Stack → OpenAI
# LLM_MODE=local             — Llama Stack → in-cluster vLLM (OpenShift AI)
#
# Per-component targets: make help
#
# Local testing (push to your Quay org, then deploy with the same REGISTRY):
#   make build REGISTRY=quay.io/rh-ai-quickstart APP_IMAGE_NAME=general-sim-api
#   make deploy REGISTRY=quay.io/rh-ai-quickstart APP_IMAGE_NAME=general-sim-api \
#     PG_PASSWORD=<pw> NEO4J_PASSWORD=<pw> OPENAI_API_KEY=<key>
# =============================================================================

# ── Configurable variables ────────────────────────────────────────────────────
REGISTRY         ?= quay.io/rh-ai-quickstart
NAMESPACE        ?= general-simulation
TAG              ?= latest
APP_IMAGE_NAME   ?= general-sim-api
POSTGRES_IMAGE_NAME ?= general-sim-postgres
PG_PASSWORD      ?=
NEO4J_PASSWORD   ?=
OPENAI_API_KEY   ?=
MAAS_API_TOKEN   ?=
HF_TOKEN         ?=
LLM_MODE         ?= maas
CHART_REPO_URL   ?= https://rh-ai-quickstart.github.io/general-simulation
LLM_SERVICE_CHART_REPO ?= https://rh-ai-quickstart.github.io/ai-architecture-charts
LLM_SERVICE_VERSION    ?= 0.5.9
LLAMA_STACK_VERSION    ?= 0.8.5

# ── Derived image references ──────────────────────────────────────────────────
IMG_POSTGRES := $(REGISTRY)/$(POSTGRES_IMAGE_NAME):$(TAG)
IMG_APP      := $(REGISTRY)/$(APP_IMAGE_NAME):$(TAG)

# ── Helm chart paths ──────────────────────────────────────────────────────────
CHART_POSTGRES  := deploy/helm/postgres
CHART_NEO4J     := deploy/helm/neo4j
CHART_BOOTSTRAP := deploy/helm/bootstrap
CHART_API       := deploy/helm/api
CHART_INGESTION := deploy/helm/ingestion
CHART_UMBRELLA  := deploy/helm/general-simulation
HELM_VALUES_DIR := helm
CHART_VALUES    := $(HELM_VALUES_DIR)/values.yaml
CHART_VALUES_MODE := $(HELM_VALUES_DIR)/values-$(LLM_MODE).yaml
CHART_VALUES_SECRETS := $(HELM_VALUES_DIR)/values-secrets.yaml
LLM_SERVICE_STANDALONE_VALUES := deploy/helm/llm-service-standalone.yaml

# Common flags passed to every helm command
HELM_RELEASE_NAME ?= general-simulation
HELM_COMMON := --namespace $(NAMESPACE) --create-namespace

# Stack model ids (providerKey/model.id) — defaults match values-local.yaml
LOCAL_MODEL_KEY  ?= deepseek-r1-distill-qwen-1-5b
LOCAL_MODEL_ID   ?= deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B

# ── Phony declarations ────────────────────────────────────────────────────────
.PHONY: all help \
        build build-postgres build-app \
        deploy deploy-umbrella \
        deploy-postgres deploy-neo4j deploy-bootstrap deploy-llm-service \
        deploy-api deploy-ingestion neo4j-connect \
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
	@printf "  %-40s %s\n" "  LLM_MODE=maas (default)" "  Stack → LiteMaaS"
	@printf "  %-40s %s\n" "  LLM_MODE=openai OPENAI_API_KEY=…" "  Stack → OpenAI"
	@printf "  %-40s %s\n" "  LLM_MODE=local HF_TOKEN=…" "  Stack → in-cluster vLLM (OpenShift AI)"
	@printf "  %-40s %s\n" "deploy-postgres / deploy-neo4j / …" "Advanced per-component installs"
	@printf "  %-40s %s\n" "neo4j-connect" "Port-forward Neo4j Browser + Bolt"
	@printf "  %-40s %s\n" "package-chart" "Package umbrella chart into dist/"
	@printf "  %-40s %s\n" "undeploy" "Uninstall Helm releases"
	@printf "  %-40s %s\n" "status" "helm list + oc get pods"
	@printf "  %-40s %s\n" "lint-charts" "helm lint"
	@printf "  %-40s %s\n" "smoke-test" "Seed UK demo + POST /query (scripts/smoke-uk-closure.sh)"
	@printf "\nVariables:\n"
	@printf "  %-18s %s\n" "LLM_MODE"         "$(LLM_MODE)  (maas | openai | local)"
	@printf "  %-18s %s\n" "REGISTRY"         "$(REGISTRY)"
	@printf "  %-18s %s\n" "APP_IMAGE_NAME"   "$(APP_IMAGE_NAME)"
	@printf "  %-18s %s\n" "NAMESPACE"        "$(NAMESPACE)"
	@printf "  %-18s %s\n" "TAG"              "$(TAG)"
	@printf "  %-18s %s\n" "PG_PASSWORD"      "(or global.postgres.password in values-secrets.yaml)"
	@printf "  %-18s %s\n" "NEO4J_PASSWORD"   "(or global.neo4j.password in values-secrets.yaml)"
	@printf "  %-18s %s\n" "MAAS_API_TOKEN"   "(maas mode; or values-secrets.yaml)"
	@printf "  %-18s %s\n" "OPENAI_API_KEY"   "(openai mode; or values-secrets.yaml)"
	@printf "  %-18s %s\n" "HF_TOKEN"         "(local mode; or values-secrets.yaml)"
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
	@LLM_MODE="$(LLM_MODE)" \
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
## (+ llm-service when LLM_MODE=local).
deploy: deploy-umbrella

deploy-umbrella: _guard-deploy-secrets \
                 _guard-oc _guard-helm _deploy-namespace _remove-orphan-neo4j-resources
	@echo "==> Updating umbrella chart dependencies..."
	helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
	helm repo update neo4j
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm dependency update $(CHART_UMBRELLA)
	@echo "==> Deploying umbrella (LLM_MODE=$(LLM_MODE))..."
	@LLM_MODE="$(LLM_MODE)" \
	 CHART_VALUES_SECRETS="$(CHART_VALUES_SECRETS)" \
	 PG_PASSWORD="$(PG_PASSWORD)" \
	 NEO4J_PASSWORD="$(NEO4J_PASSWORD)" \
	 MAAS_API_TOKEN="$(MAAS_API_TOKEN)" \
	 OPENAI_API_KEY="$(OPENAI_API_KEY)" \
	 HF_TOKEN="$(HF_TOKEN)" \
	 . ./helm/resolve-deploy-secrets.sh; \
	helm_args="-f $(CHART_VALUES)"; \
	if [ "$(LLM_MODE)" != "maas" ]; then \
	  helm_args="$$helm_args -f $(CHART_VALUES_MODE)"; \
	fi; \
	if [ -f "$(CHART_VALUES_SECRETS)" ]; then \
	  helm_args="$$helm_args -f $(CHART_VALUES_SECRETS)"; \
	fi; \
	helm upgrade --install $(HELM_RELEASE_NAME) $(CHART_UMBRELLA) \
	  $(HELM_COMMON) \
	  $$helm_args \
	  --set global.registry=$(REGISTRY) \
	  --set global.imageTag=$(TAG) \
	  --set global.images.app=$(APP_IMAGE_NAME) \
	  --set global.images.postgres=$(POSTGRES_IMAGE_NAME) \
	  $$SECRET_HELM_ARGS \
	  --wait --timeout $(if $(filter local,$(LLM_MODE)),25m,15m)
	@printf "\n==> Deployment complete (LLM_MODE=$(LLM_MODE)).\n"
	@printf "    API (same-NS):  http://general-sim-api:8000\n"
	@printf "    Llama Stack:    http://llamastack:8321/v1\n"
	@printf "    Smoke test:\n"
	@printf "      ROUTE=\$$(oc get route general-sim-api -n $(NAMESPACE)"
	@printf " -o jsonpath='{.spec.host}')\n"
	@printf "      curl -s https://\$$ROUTE/health | jq .\n"
	@printf "      SEED_MODE=cluster make smoke-test NAMESPACE=$(NAMESPACE)\n"
	@printf "    Neo4j Browser: make neo4j-connect NAMESPACE=$(NAMESPACE)\n\n"

# ── Advanced: per-component targets ───────────────────────────────────────────

deploy-postgres: _guard-pg-password _guard-oc _guard-helm _deploy-namespace
	@echo "==> Deploying Postgres..."
	helm upgrade --install postgres $(CHART_POSTGRES) \
	  $(HELM_COMMON) \
	  --set image=$(IMG_POSTGRES) \
	  --set-string global.postgres.password='$(PG_PASSWORD)' \
	  --wait --timeout 5m
	@echo "    Postgres ready."

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

deploy-bootstrap: _guard-pg-password _guard-neo4j-password _guard-helm
	helm upgrade --install bootstrap $(CHART_BOOTSTRAP) \
	  $(HELM_COMMON) \
	  --set image=$(IMG_APP) \
	  --set-string global.postgres.password='$(PG_PASSWORD)' \
	  --set-string global.neo4j.password='$(NEO4J_PASSWORD)' \
	  --atomic --timeout 3m
	@echo "    Bootstrap complete."

deploy-llm-service: _guard-helm _guard-oc _deploy-namespace
	@test -n "$(HF_TOKEN)" || \
	  { printf "ERROR: HF_TOKEN is required.\n"; exit 1; }
	@echo "==> Deploying llm-service only (prefer: make deploy LLM_MODE=local)..."
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm upgrade --install llm-service ai-architecture-charts/llm-service \
	  --version $(LLM_SERVICE_VERSION) \
	  $(HELM_COMMON) \
	  -f $(LLM_SERVICE_STANDALONE_VALUES) \
	  --set-string secret.hf_token='$(HF_TOKEN)' \
	  --wait --timeout 20m
	@printf "    In-cluster vLLM via llm-service (umbrella LLM_MODE=local wires Stack).\n\n"

deploy-api: _guard-pg-password _guard-neo4j-password _guard-helm
	helm upgrade --install api $(CHART_API) \
	  $(HELM_COMMON) \
	  --set image=$(IMG_APP) \
	  --set-string global.postgres.password='$(PG_PASSWORD)' \
	  --set-string global.neo4j.password='$(NEO4J_PASSWORD)' \
	  --set-string llm.apiKey='$(OPENAI_API_KEY)' \
	  --wait --timeout 3m
	@oc get route general-sim-api -n $(NAMESPACE) \
	  -o jsonpath='    API:    https://{.spec.host}/health{"\n"}' 2>/dev/null || true

deploy-ingestion: _guard-pg-password _guard-neo4j-password _guard-helm
	helm upgrade --install ingestion $(CHART_INGESTION) \
	  $(HELM_COMMON) \
	  --set image=$(IMG_APP) \
	  --set-string global.postgres.password='$(PG_PASSWORD)' \
	  --set-string global.neo4j.password='$(NEO4J_PASSWORD)' \
	  --set-string llm.apiKey='$(OPENAI_API_KEY)' \
	  --wait --timeout 2m
	@echo "    Ingestion CronJob configured."

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
	@oc delete serviceaccount neo4j-sa -n $(NAMESPACE) --ignore-not-found >/dev/null
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
	@for chart in \
	  $(CHART_POSTGRES) \
	  $(CHART_BOOTSTRAP) \
	  $(CHART_API) \
	  $(CHART_INGESTION); do \
	  printf "==> Linting $$chart ...\n"; \
	  helm lint "$$chart" || exit 1; \
	done
	@echo "==> Updating and linting umbrella chart..."
	helm repo add neo4j https://helm.neo4j.com/neo4j 2>/dev/null || true
	helm repo update neo4j
	helm repo add ai-architecture-charts $(LLM_SERVICE_CHART_REPO) 2>/dev/null || true
	helm repo update ai-architecture-charts
	helm dependency update $(CHART_UMBRELLA)
	helm lint $(CHART_UMBRELLA)
	@echo "==> All charts passed lint."

smoke-test:
	@chmod +x scripts/smoke-uk-closure.sh
	./scripts/smoke-uk-closure.sh
