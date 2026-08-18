#!/usr/bin/env bash
# Lightweight enable/disable gate for nightly agent workflows.
#
# Reads sandcastle.config.json's `disabledWorkflows` array and exits 1 (skip)
# when the current workflow name is listed — letting a repo owner turn off a
# nightly agent pass without editing the vendored workflow file.
#
# Usage:
#   bash .sandcastle/scripts/check-workflow-enabled.sh architecture-review
#   echo "enabled=$enabled" >> "$GITHUB_OUTPUT"

set -euo pipefail

WORKFLOW_NAME="${1:-}"
if [[ -z "$WORKFLOW_NAME" ]]; then
    echo "check-workflow-enabled: WORKFLOW_NAME argument is required." >&2
    exit 2
fi

CONFIG_FILE="sandcastle.config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "enabled=true"  # No config — default to enabled
    exit 0
fi

if command -v jq >/dev/null 2>&1; then
    disabled=$(jq -r '.disabledWorkflows // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
else
    # Fallback without jq: naive grep for the workflow name in disabledWorkflows
    disabled=$(grep -A5 '"disabledWorkflows"' "$CONFIG_FILE" 2>/dev/null | grep -o "\"[^\"]*\"" | tr -d '"' | grep -v disabledWorkflows || true)
fi

if printf '%s\n' "$disabled" | grep -qx "$WORKFLOW_NAME"; then
    echo "check-workflow-enabled: $WORKFLOW_NAME is disabled via sandcastle.config.json (disabledWorkflows)." >&2
    echo "enabled=false"
    exit 0
fi

echo "enabled=true"