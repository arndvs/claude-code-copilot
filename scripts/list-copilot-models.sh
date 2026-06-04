#!/usr/bin/env bash
# list-copilot-models.sh — List available GitHub Copilot chat models
# and output them ready to paste into litellm_config.yaml
#
# Usage: ./list-copilot-models.sh [--enabled-only]
#
# Requires: proxy authenticated at least once (token at ~/.config/litellm/github_copilot/access-token)

set -euo pipefail

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ $cmd is required but not installed." >&2
        echo "   Install it and try again." >&2
        exit 1
    fi
done

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

# Write auth header to a restricted temp file so the token never appears in
# curl's argv (visible via /proc/*/cmdline or ps).
CURL_CONFIG=$(mktemp "${TMPDIR:-/tmp}/copilot-curl-XXXXXX")
chmod 600 "$CURL_CONFIG"
cleanup() { rm -f "$CURL_CONFIG"; }
trap cleanup EXIT
printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" > "$CURL_CONFIG"

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

curl -qsf -K "$CURL_CONFIG" \
    https://api.githubcopilot.com/models \
| jq -r '.data[]
    | select(.capabilities.type == "chat")
    | '"$FILTER"'
    | "  - model_name: " + .id + "\n"
    + "    litellm_params:\n"
    + "      model: github_copilot/" + .id + "\n"
    + "      drop_params: true\n"
    + "      extra_headers:\n"
    + "        Editor-Version: \"vscode/1.106.3\"\n"
    + "        Editor-Plugin-Version: \"copilot/1.388.0\"\n"
    + "        Copilot-Integration-Id: \"vscode-chat\"\n"
    + "        User-Agent: \"GithubCopilot/1.388.0\"\n"
    + "    # " + .name + " (" + .vendor + ")"
    + " — state: " + (.policy.state // "enabled")
    + " | max output: " + (.capabilities.limits.max_output_tokens | tostring) + " tokens"
    + " | context: " + (.capabilities.limits.max_context_window_tokens | tostring) + " tokens\n"
'
