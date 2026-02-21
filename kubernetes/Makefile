CLUSTER_NAME := local-gitops
KIND := kind
KUBECTL := kubectl
HELM := helm
REQUIRED_TOOLS := $(KIND) $(KUBECTL) $(HELM) docker

.PHONY: help up down check-tools cluster-create install-ingress install-argocd install-gitea install-ingress-routes info deploy-app

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-tools: ## Check if required tools are installed
	@echo "Checking dependencies..."
	@for tool in $(REQUIRED_TOOLS); do \
		command -v $$tool >/dev/null 2>&1 || { echo "Error: $$tool is not installed"; exit 1; }; \
	done
	@echo "All dependencies check out!"

up: check-tools cluster-create install-ingress install-argocd install-gitea install-ingress-routes info ## Create cluster and install all components with Ingress

down: ## Delete the Kind cluster
	$(KIND) delete cluster --name $(CLUSTER_NAME)

cluster-create: ## Create the Kind cluster with port mappings
	@echo "Creating Kind cluster..."
	@if $(KIND) get clusters | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster $(CLUSTER_NAME) already exists"; \
	else \
		$(KIND) create cluster --name $(CLUSTER_NAME) --config kind-config.yaml; \
	fi
	$(KUBECTL) cluster-info --context kind-$(CLUSTER_NAME)

install-ingress: ## Install NGINX Ingress Controller
	@echo "Installing NGINX Ingress Controller..."
	$(KUBECTL) apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	@echo "Waiting for Ingress Controller to be ready..."
	$(KUBECTL) rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s
	@echo "Ingress Controller installed."

install-argocd: ## Install ArgoCD into the cluster
	@echo "Installing ArgoCD..."
	$(KUBECTL) create namespace argocd --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side --force-conflicts
	@echo "Waiting for ArgoCD components to be ready..."
	$(KUBECTL) wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
	@echo "ArgoCD installed."

install-gitea: ## Install Gitea into the cluster
	@echo "Installing Gitea..."
	$(KUBECTL) apply -f manifests/gitea-deployment.yaml
	@echo "Waiting for Gitea to be ready..."
	$(KUBECTL) wait --for=condition=available --timeout=300s deployment/gitea -n gitea
	@echo "Gitea installed."

install-ingress-routes: ## Apply Ingress routes for Gitea and ArgoCD
	@echo "Configuring Ingress routes..."
	$(KUBECTL) apply -f manifests/ingress.yaml
	@echo "Ingress routes configured."

deploy-app: ## Deploy an application using the Helm chart (requires NAME and VALUES)
	@echo "Deploying application using Helm chart..."
	# Usage: make deploy-app NAME=my-app VALUES=my-values.yaml
	$(HELM) upgrade --install $(NAME) charts/argocd-app -f $(VALUES) -n argocd

info: ## Show access information for ArgoCD and Gitea
	@echo "========================================================"
	@echo "Access Information:"
	@echo "--------------------------------------------------------"
	@echo "ArgoCD:"
	@echo "  URL: https://argocd.localhost (Accept self-signed cert)"
	@echo "  Username: admin"
	@echo "  Password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
	@echo ""
	@echo "Gitea:"
	@echo "  URL: http://gitea.localhost"
	@echo "  User/Pass: gitea / gitea (as configured in manifest)"
	@echo "========================================================"
