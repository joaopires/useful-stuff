# Useful Stuff

A collection of useful scripts, configurations, and tools for daily development workflows.

## 📁 Repository Structure

### 🛠 Scripts (`/sh`)

A collection of useful shell scripts. See [sh/README.md](sh/README.md) for detailed documentation.

- **Jira Tools (`/sh/jira`)**:
  - `create_tickets.sh`: Bulk create Jira tickets from CSV.

### ⚙️ Git Utilities (`/git`)

A collection of useful Git hooks and utilities. See [git/README.md](git/README.md) for detailed documentation.

- **Hooks (`/git/hooks`)**:
  - `post-worktree-add.sh`: Automate environment setup after adding a git worktree.

### 🐚 Zsh Plugins (`/oh-my-zsh`)

Custom plugins for Zsh. See [oh-my-zsh/README.md](oh-my-zsh/README.md) for detailed documentation.

- **Bare Clone (`/oh-my-zsh/bare-clone`)**:
  - `bare-clone.plugin.zsh`: Automates the setup of a bare repository with worktree support.

### ☸️ Kubernetes (`/kubernetes`)

A complete local GitOps environment using Kind, ArgoCD, and Gitea.

- **Features**:
  - Automated Kind cluster creation with port mappings (80/443).
  - Pre-installed ArgoCD and Gitea.
  - Ingress configuration for localhost access.
  - Helm chart for creating ArgoCD Applications.
  - Interactive CLI for deploying apps.

- **Usage**:
  - `make up`: Spin up the entire environment.
  - `make deploy-app`: Interactively deploy a new application to ArgoCD.
  - `make down`: Destroy the cluster.

- **Access**:
  - Gitea: `http://gitea.localhost`
  - ArgoCD: `https://argocd.localhost`
