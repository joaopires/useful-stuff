CLUSTER_NAME := local-gitops
KIND := kind
KUBECTL := kubectl
HELM := helm
REQUIRED_TOOLS := $(KIND) $(KUBECTL) $(HELM) docker

# Allow overriding the command name for help text (e.g., when wrapped by a script)
CMD ?= make

.PHONY: help up down check-tools cluster-create install-ingress install-argocd install-gitea install-ingress-routes info deploy-app deploy-apps

help: ## Show this help message
	@echo "Usage: $(CMD) [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sed 's/make /$(CMD) /g'

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

deploy-apps: ## Deploy multiple apps from a folder (Usage: make deploy-apps FOLDER=path/to/folder)
	@if [ -z "$(FOLDER)" ]; then echo "FOLDER is required"; exit 1; fi
	@echo "Deploying apps from $(FOLDER)..."
	@for file in $(FOLDER)/*.yaml; do \
		if [ ! -f "$$file" ]; then continue; fi; \
		app_name=$$(basename $$file .yaml); \
		echo "Deploying $$app_name..."; \
		$(HELM) upgrade --install $$app_name charts/argocd -n argocd --set name=$$app_name -f $$file; \
	done

deploy-app: ## Deploy an application interactively or from a file (Usage: make deploy-app [FILE=path/to/app.yaml])
	@if [ -n "$(FILE)" ]; then \
		echo "Deploying application from $(FILE)..."; \
		if [ ! -f "$(FILE)" ]; then echo "Error: File $(FILE) not found"; exit 1; fi; \
		app_name=$$(basename $(FILE) .yaml); \
		echo "Deploying $$app_name..."; \
		$(HELM) upgrade --install $$app_name charts/argocd -n argocd --set name=$$app_name -f $(FILE); \
	else \
		echo "Deploying application using Helm chart (Interactive Mode)..."; \
		read -p "Enter Application Name (this will be the ArgoCD Application name): " name; \
		if [ -z "$$name" ]; then echo "Name is required"; exit 1; fi; \
		read -p "Enter ArgoCD Project [default]: " project; \
		project=$${project:-default}; \
		read -p "Enter Repository Name (the name given to the repository upon creation): " repo_name; \
		if [ -z "$$repo_name" ]; then echo "Repo Name is required"; exit 1; fi; \
		read -p "Enter Path in Repository (root path to helm charts or manifests inside the repository): " path; \
		read -p "Enter Target Namespace: " dest_ns; \
		echo "Enter value files separated by commas (e.g., values.yaml,values-dev.yaml)."; \
		echo "  - Required ONLY if deploying a Helm chart."; \
		echo "  - Order matters! Later files override earlier ones."; \
		read -p "Enter Value Files (optional): " value_files_input; \
		\
		echo "Deploying $$name..."; \
		cmd="$(HELM) upgrade --install $$name charts/argocd -n argocd \
			--set name=$$name \
			--set project=$$project \
			--set repoName=$$repo_name \
			--set path=$$path \
			--set destinationNamespace=$$dest_ns"; \
		\
		if [ -n "$$value_files_input" ]; then \
			IFS=',' read -r -a vfs <<< "$$value_files_input"; \
			i=0; \
			for vf in "$${vfs[@]}"; do \
				cmd="$$cmd --set helm.valueFiles[$$i]=$$vf"; \
				i=$$((i+1)); \
			done; \
		fi; \
		\
		echo "Running: $$cmd"; \
		eval $$cmd; \
	fi

info: ## Show access information for ArgoCD and Gitea
	@echo "Checking service status..."
	@if $(KUBECTL) get deployment -n argocd argocd-server >/dev/null 2>&1 && \
	    $(KUBECTL) get deployment -n gitea gitea >/dev/null 2>&1; then \
		echo "========================================================"; \
		echo "Access Information:"; \
		echo "--------------------------------------------------------"; \
		echo "ArgoCD:"; \
		echo "  URL: https://argocd.localhost (Accept self-signed cert)"; \
		echo "  Username: admin"; \
		echo "  Password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"; \
		echo ""; \
		echo "Gitea:"; \
		echo "  URL: http://gitea.localhost"; \
		echo "  User/Pass: gitea / gitea (as configured in manifest)"; \
		echo "========================================================"; \
	else \
		echo "Services are not fully ready yet. Please run 'up' or wait a few moments."; \
	fi
