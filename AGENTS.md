# Agent Guide to `useful-stuff`

This repository is a collection of developer utilities, scripts, and configurations. It is organized by tool or technology.

## 📂 Repository Structure

* **`git/`**: Git hooks and configuration helpers.
  * `hooks/post-worktree-add.sh`: Script to automate setup after creating a new git worktree.
* **`kubernetes/`**: A complete local GitOps environment.
  * Uses Kind, ArgoCD, and Gitea.
  * Managed via `Makefile`.
* **`oh-my-zsh/`**: Custom Zsh plugins.
  * `bare-clone/`: Plugin to automate bare repository setup with worktrees.
* **`sh/`**: General shell scripts.
  * `jira/`: Tools for interacting with Jira (e.g., bulk ticket creation).

## 🚀 Key Workflows

### Kubernetes Environment

The `kubernetes/` directory contains a self-contained local platform.

* **Start**: `make up` (in `kubernetes/` dir) - Spins up Kind, installs ArgoCD & Gitea.
* **Deploy**: `make deploy-app` - Interactive script to deploy apps to ArgoCD.
* **Stop**: `make down` - Destroys the Kind cluster.
* **Access**:
  * Gitea: `http://gitea.localhost`
  * ArgoCD: `https://argocd.localhost`

### Scripts

* **Jira**: `sh/jira/create_tickets.sh` is used for bulk ticket creation from CSV. Requires `JIRA_AUTH` env var.

## ⚠️ Guidelines for Agents

1. **Context is Key**: When asked to modify a script, check the corresponding `README.md` in that subdirectory (e.g., `git/README.md`) for specific usage instructions.
2. **Makefiles**: The `kubernetes/Makefile` is the source of truth for the local infrastructure. Read it to understand the deployment flow.
3. **Idempotency**: Scripts should ideally be idempotent. If modifying them, ensure they handle re-runs gracefully.
4. **Dependencies**: Be aware that scripts might depend on external tools (e.g., `kind`, `helm`, `kubectl`, `jq`).
5. **Documentation**: Whenever you modify code, scripts, or workflows, you MUST update the corresponding `README.md` to reflect the changes (e.g., new flags, changed behavior, usage instructions).
6. **Self-Maintenance**: If your changes alter the repository structure, workflows, or add new tools/scripts, you MUST update this `AGENTS.md` file to keep it accurate and useful for future agents.

## 📝 Commit Standards

Agents must follow **Conventional Commits** for all commit messages.

* **Structure**: `type(scope): description`
* **Types**:
  * `feat`: A new feature
  * `fix`: A bug fix
  * `docs`: Documentation only changes
  * `style`: Changes that do not affect the meaning of the code (white-space, formatting, etc)
  * `refactor`: A code change that neither fixes a bug nor adds a feature
  * `perf`: A code change that improves performance
  * `test`: Adding missing tests or correcting existing tests
  * `chore`: Changes to the build process or auxiliary tools and libraries such as documentation generation
* **Scope** (Optional): The directory or component affected (e.g., `kubernetes`, `jira`, `git`).
* **Example**: `feat(kubernetes): add ingress controller support`

## 📦 Release Generation

When asked to prepare a release or if you've completed a significant set of features/fixes that warrant a release:

1. **Determine Version**: Check the latest release and determine the next version number based on Semantic Versioning (major, minor, or patch) and your changes.
2. **Create Release**:
    * Draft a new release in GitHub.
    * Tag: Use the version number (e.g., `v1.2.3`).
    * Title: `Release v1.2.3` (or similar).
    * Description: Generate release notes based on the changes (Conventional Commits help here).
3. **Automation**: Publishing the release will automatically trigger the `.github/workflows/update-homebrew.yml` workflow.
    * This workflow updates the Homebrew formula in the `joaopires/homebrew-tap` repository.
    * It calculates the SHA256 of the source code tarball and updates the formula to point to the new tag.
4. **Verification**:
    * Monitor the "Update Homebrew Formula" action in the Actions tab.
    * Once successful, the `local-gitops` tool can be upgraded via `brew upgrade local-gitops` (users might need to `brew update` first).
