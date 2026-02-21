# ☸️ Local GitOps Environment

This directory contains a complete, self-contained local GitOps platform running on Kubernetes (Kind). It includes a Git server (Gitea) and a Continuous Delivery tool (ArgoCD), pre-wired to work together.

## 🚀 Features

- **Kind Cluster**: Automated cluster creation with custom port mappings (80/443).
- **Gitea**: Local self-hosted Git service, accessible at `http://gitea.localhost`.
- **ArgoCD**: Declarative continuous delivery, accessible at `https://argocd.localhost`.
- **Ingress**: NGINX Ingress Controller configured for localhost access.
- **App Factory**: A Helm chart (`charts/argocd`) designed to easily template ArgoCD Applications pointing to local Gitea repositories.

## 📋 Prerequisites

Ensure you have the following installed:

- [Docker](https://docs.docker.com/get-docker/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [Kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

## 🛠 Usage

The entire lifecycle is managed via the `Makefile`.

### 1. Start the Environment

Create the cluster and install all components:

```bash
make up
```

*This may take a few minutes. It will verify tools, create the cluster, and install Ingress, ArgoCD, and Gitea.*

### 2. Access the Tools

Once `make up` completes, you can access:

- **Gitea**: [http://gitea.localhost](http://gitea.localhost)
  - **User/Pass**: `gitea` / `gitea` (default admin)
- **ArgoCD**: [https://argocd.localhost](https://argocd.localhost)
  - **Username**: `admin`
  - **Password**: (Printed at the end of `make up`, or run `make info`)
  - *Note: Accept the self-signed certificate warning.*

### 3. Deploy an Application

To deploy a new application from a Gitea repository to ArgoCD:

1. **Create a Repo**: Create a repository in Gitea (e.g., `my-app`) and push your Helm chart or manifests to it.
2. **Run Deploy Wizard**:

    ```bash
    make deploy-app
    ```

3. **Follow Prompts**:
    - **App Name**: Name for the ArgoCD Application (e.g., `my-app`).
    - **Project**: ArgoCD project (default: `default`).
    - **Repo Name**: The name of your Gitea repository (e.g., `my-app`).
    - **Path**: Path to charts/manifests inside the repo (e.g., `charts/my-app` or `.`).
    - **Namespace**: Target namespace for the app (e.g., `my-app-dev`).
    - **Value Files**: Optional list of value files (e.g., `values.yaml`).

### 4. Stop the Environment

To destroy the cluster and clean up:

```bash
make down
```

## 📂 Structure

- **`Makefile`**: Automation scripts.
- **`kind-config.yaml`**: Kind cluster configuration with port mappings.
- **`charts/argocd/`**: A Helm chart used to template ArgoCD Application resources.
- **`manifests/`**: Raw Kubernetes manifests for infrastructure (Gitea, Ingress).
