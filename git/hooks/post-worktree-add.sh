#!/bin/bash

# $1 is the path to the new worktree
NEW_WORKTREE_PATH="$1"

# The path to the main .vscode folder (adjust this absolute path for your machine!)
MAIN_VSCODE_PATH="/path/to/my-repo-main/.vscode" 

# Create the symlink
ln -s "$MAIN_VSCODE_PATH" "$NEW_WORKTREE_PATH/.vscode"

echo "VS Code configuration symlinked from $MAIN_VSCODE_PATH to $NEW_WORKTREE_PATH/.vscode"
