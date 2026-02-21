# Homebrew Tap for Local GitOps

This directory contains the Homebrew Formula to install the `kubernetes` environment as a package.

## 📦 How to Release

1. **Create a Release on GitHub**:
    - Go to your repository on GitHub.
    - Draft a new release (e.g., `v0.1.0`).
    - Publish it.

2. **Get the SHA256 Checksum**:
    - Download the source code tarball (e.g., `v0.1.0.tar.gz`) from the release page.
    - Run `shasum -a 256 v0.1.0.tar.gz`.

3. **Update the Formula**:
    - Edit `packaging/k8s/homebrew/local-gitops.rb`.
    - Update the `url` to point to the new release tarball.
    - Update the `sha256` with the checksum you calculated.

## 🚀 How Users Install It

To let users install this easily, you should create a **Tap**.

1. **Create a New Repository**:
    - Name it `homebrew-tap` (or `homebrew-useful-stuff`).
    - It can be public.

2. **Add the Formula**:
    - Copy `packaging/k8s/homebrew/local-gitops.rb` to the root of your new `homebrew-tap` repository.
    - Commit and push.

3. **Usage**:
    Users can now run:

    ```bash
    brew tap joaopires/tap  # OR your-username/tap
    brew install local-gitops
    ```

    And then run the tool:

    ```bash
    local-gitops up
    ```

## 🧪 Local Testing

You can test the formula locally before publishing:

```bash
brew install --build-from-source ./packaging/k8s/homebrew/local-gitops.rb
```

## 🤖 Automation (Optional)

A GitHub Action is included in this repository to automatically update the formula in your tap repository when you create a new release.

### Prerequisites

1. **Create a Personal Access Token (PAT)**:
    - Go to [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens).
    - Generate a new token (classic).
    - Scopes: Select `repo` (Full control of private repositories) or `public_repo` (if tap is public).
    - Copy the token.

2. **Add Secret to Repository**:
    - Go to *this* repository's settings (not the tap).
    - Navigate to **Secrets and variables > Actions**.
    - Click **New repository secret**.
    - Name: `PAT_TOKEN`
    - Value: Paste your PAT.

### How it Works

When you publish a release in this repo:

1. The workflow calculates the new SHA256.
2. It checks out your `homebrew-tap` repository.
3. It updates `local-gitops.rb` with the new version and checksum.
4. It commits and pushes the changes.
