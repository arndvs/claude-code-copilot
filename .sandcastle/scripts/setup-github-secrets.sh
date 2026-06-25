#!/bin/bash
set -euo pipefail

# ============================================================
# Sandcastle — GitHub Secrets Setup
# ============================================================
#
# Walks you through setting the secrets needed for agent
# workflows to authenticate with the Copilot-backed LiteLLM proxy and GitHub.
#
# Secrets configured:
#
#   1. LITELLM_BASE_URL
#      Base URL for the LiteLLM proxy that routes model traffic
#      to GitHub Copilot.
#
#   2. LITELLM_MASTER_KEY
#      Auth token for the LiteLLM proxy.
#
#   3. AGENT_PAT
#      A GitHub Personal Access Token (classic) with repo scope.
#      Required for label mutations that trigger downstream workflows
#      (GITHUB_TOKEN cannot trigger other workflow runs).
#
#      Create at: https://github.com/settings/tokens
#      Required scope: repo
#
# ============================================================

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)

if [[ -z "$REPO" ]]; then
  echo "Error: Could not determine repo. Make sure you're in a git repo with a GitHub remote."
  exit 1
fi

echo "Setting up secrets for: $REPO"
echo ""

set_secret() {
  local name="$1"
  local description="$2"
  local instructions="$3"

  echo "--- $name ---"
  echo ""
  echo "  $description"
  echo "  $instructions"
  echo ""

  local existing
  existing=$(gh secret list --repo "$REPO" 2>/dev/null | awk '{print $1}' | grep -Fx "$name" || true)
  if [[ -n "$existing" ]]; then
    echo "  [Already set] $name exists. Overwrite? (y/N)"
    read -r overwrite
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
      echo "  Skipping."
      echo ""
      return
    fi
  fi

  echo "  Paste your $name (input is hidden):"
  read -rs token
  if [[ -z "$token" ]]; then
    echo "  Error: $name cannot be empty; secret was not changed." >&2
    return 1
  fi
  printf '%s' "$token" | gh secret set "$name" --repo "$REPO"
  echo "  Set."
  echo ""
}

set_secret "LITELLM_BASE_URL" \
  "Base URL for the LiteLLM proxy that routes Claude-compatible traffic to GitHub Copilot." \
  "Use the HTTPS URL for your LiteLLM proxy, without an Anthropic API key."

set_secret "LITELLM_MASTER_KEY" \
  "Auth token for the LiteLLM proxy." \
  "Use the proxy master key expected by your LiteLLM deployment."

set_secret "AGENT_PAT" \
  "GitHub PAT (classic) with repo scope; required for label handoffs that trigger downstream workflows." \
  "Create at: https://github.com/settings/tokens — scope: repo"

# --- Verify ---

echo "============================================================"
echo "Secrets configured for $REPO:"
echo ""
gh secret list --repo "$REPO"
echo ""
echo "============================================================"
