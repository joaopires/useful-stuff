# ~/.oh-my-zsh/custom/plugins/bare-clone/bare-clone.plugin.zsh

# Defines the custom git command as a Zsh function
function git-bare-clone() {
  # 1. Check for required arguments
  if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: git bare-clone <repository.git> <destination>"
    return 1
  fi

  local REPO_URL="$1"
  local DEST_DIR="$2"
  local BARE_DIR=".bare"

  echo "Starting bare clone workflow..."

  # --- Core Git Commands ---
  # Clone the bare repository into the hidden .bare directory
  git clone --bare "${REPO_URL}" "${DEST_DIR}/${BARE_DIR}"
  if [ $? -ne 0 ]; then
    echo "Error: git clone failed."
    return 1
  fi

  # Create the destination directory and redirect the Git path
  mkdir -p "${DEST_DIR}"
  echo "gitdir: ./${BARE_DIR}" > "${DEST_DIR}/.git"

  # Change to the destination directory to run subsequent commands
  cd "${DEST_DIR}" || return

  # Configure the fetch refspec (Crucial for seeing remotes)
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

  # Fetch the remote data (populates refs/remotes/origin/*)
  git fetch origin

  # Set up upstream tracking for all branches
  echo "Setting upstream tracking for all branches..."
  git for-each-ref --format='%(refname:short)' refs/heads | xargs -n1 -I{} git branch --set-upstream-to=origin/{} {}

  echo "✅ Bare clone setup complete in: ${DEST_DIR}"
  echo "You can now add worktrees from here: git worktree add <path> <branch>"
}

# Alias to make the function runnable as 'git bare-clone'
alias gitbare-clone="git-bare-clone"
