# ⚙️ Git Utilities

A collection of useful Git hooks and utilities.

## Hooks (`/hooks`)

### `post-worktree-add.sh`

A script designed to automate environment setup (like symlinking `.vscode` folders) after adding a new git worktree.

#### Setup

1. Edit `hooks/post-worktree-add.sh` to set your `MAIN_VSCODE_PATH`.
2. To use it in a repository, symlink it to your local hooks:

   ```bash
   ln -s /path/to/useful-stuff/git/hooks/post-worktree-add.sh .git/hooks/post-worktree-add
   ```

   *Note: Standard Git does not natively support `post-worktree-add`. You may need to call this script from `post-checkout` or use a hook manager that supports it.*
