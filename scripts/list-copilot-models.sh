#!/usr/bin/env bash
# list-copilot-models.sh — List available GitHub Copilot chat models
# and output them ready to paste into litellm_config.yaml
#
# Usage: ./list-copilot-models.sh [--enabled-only]
#
# Requires: proxy authenticated at least once (token at ~/.config/litellm/github_copilot/access-token)

set -euo pipefail

GITHUB_TOKEN_FILE="$HOME/.config/litellm/github_copilot/access-token"
ENABLED_ONLY=false

if [[ "${1:-}" == "--enabled-only" ]]; then
    ENABLED_ONLY=true
fi

if [[ ! -f "$GITHUB_TOKEN_FILE" ]]; then
    echo "❌ GitHub Copilot token not found at $GITHUB_TOKEN_FILE" >&2
    echo "   Run './start_proxy.sh' first to complete GitHub OAuth." >&2
    exit 1
fi

GITHUB_TOKEN=$(tr -d '\n\r ' < "$GITHUB_TOKEN_FILE")

echo "# GitHub Copilot chat models — generated $(date)"
echo "# Paste desired entries into litellm_config.yaml"
echo "# The default wildcard config routes everything automatically —"
echo "# explicit entries are only needed if you want per-model control."
echo ""

if [[ "$ENABLED_ONLY" == "true" ]]; then
    echo "# Showing enabled models only"
    FILTER='select(.policy.state == "enabled" or .policy == null)'
else
    echo "# Showing all models"
    FILTER='.'
fi

echo ""
echo "model_list:"

curl -sf -H "Authorization: Bearer $GITHUB_TOKEN" \
    https://api.githubcopilot.com/models \
| jq -r '.data[]
    | select(.capabilities.type == "chat")
    | '"$FILTER"'
    | "  - model_name: " + .id + "\n"
    + "    litellm_params:\n"
    + "      model: github_copilot/" + .id + "\n"
    + "      drop_params: true\n"
    + "      extra_headers:\n"
    + "        editor-version: \"vscode/1.85.1\"\n"
    + "        editor-plugin-version: \"copilot/1.155.0\"\n"
    + "        Copilot-Integration-Id: \"vscode-chat\"\n"
    + "        user-agent: \"GithubCopilot/1.155.0\"\n"
    + "    # " + .name + " (" + .vendor + ")"
    + " — state: " + (.policy.state // "enabled")
    + " | max output: " + (.capabilities.limits.max_output_tokens | tostring) + " tokens"
    + " | context: " + (.capabilities.limits.max_context_window_tokens | tostring) + " tokens\n"
'
