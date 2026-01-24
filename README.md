# Useful Stuff

A collection of useful scripts, configurations, and tools for daily development workflows.

## 📁 Repository Structure

### 🛠 Scripts (`/sh`)

- **Jira Tools (`/sh/jira`)**:
  - `create_tickets.sh`: A shell script to bulk create Jira tickets from a CSV file using Jira REST API v3. Supports dry-runs and handles Story Points, Labels, and ADF descriptions.

### ⚙️ Git Utilities (`/git`)

- **Hooks (`/git/hooks`)**:
  - `post-worktree-add.sh`: A script designed to automate environment setup (like symlinking `.vscode` folders) after adding a new git worktree.

  #### Setup:
  1. Edit `git/hooks/post-worktree-add.sh` to set your `MAIN_VSCODE_PATH`.
  2. To use it in a repository, symlink it to your local hooks:
     ```bash
     ln -s /path/to/useful-stuff/git/hooks/post-worktree-add.sh .git/hooks/post-worktree-add
     ```
     *Note: Standard Git does not natively support `post-worktree-add`. You may need to call this script from `post-checkout` or use a hook manager that supports it.*

### 🐚 Zsh Plugins (`/oh-my-zsh`)

- **Bare Clone (`/oh-my-zsh/bare-clone`)**:
  - `bare-clone.plugin.zsh`: A plugin providing the `git-bare-clone` function. It automates the setup of a bare repository with worktree support, including refspec configuration and upstream tracking.

---

## 🚀 Getting Started

To use any of the scripts, ensure they have execution permissions:

```bash
chmod +x sh/jira/create_tickets.sh
chmod +x git/hooks/post-worktree-add.sh
```

### Jira Ticket Creator Usage

```bash
export JIRA_AUTH="email@example.com:api-token"
./sh/jira/create_tickets.sh [-d] [-h] <csv_filepath> <jira_organization> <project_key>
```

### Bare Clone Plugin

To use the `git-bare-clone` plugin, source it in your `.zshrc` or copy it to your custom Oh My Zsh plugins folder.
