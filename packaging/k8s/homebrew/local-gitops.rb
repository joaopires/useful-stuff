class LocalGitops < Formula
  desc "Local GitOps environment with Kind, ArgoCD, and Gitea"
  homepage "https://github.com/joaopires/useful-stuff"
  url "https://github.com/joaopires/useful-stuff/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  license "MIT"

  depends_on "kind"
  depends_on "helm"
  depends_on "kubectl"

  def install
    # The 'kubernetes' directory contains the Makefile and other necessary files.
    # We install it into the libexec directory to keep it hidden but accessible.
    libexec.install Dir["kubernetes/*"]

    # Create a wrapper script named 'local-gitops' in the bin directory.
    # This script will execute 'make' inside the libexec directory.
    (bin/command_name).write <<~EOS
      #!/bin/bash
      # Forward all arguments to make in the installation directory
      exec make -C #{libexec} CMD=#{command_name} "$@"
    EOS
  end

  test do
    # Simple test to verify the command is available and help output works
    assert_match "Usage: #{command_name} [target]", shell_output("#{bin}/#{command_name} help")
  end

  private

  def command_name
    "local-gitops"
  end
end
