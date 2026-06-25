#!/bin/bash
set -euo pipefail

# block-npx-tsc.sh — Claude Code hook that intercepts bare `npx tsc` commands
# and redirects to the project's package-manager script instead.
#
# Install as a PreToolUse hook in .claude/settings.json:
#   { "hooks": { "PreToolUse": [{ "matcher": "Bash", "command": ".sandcastle/hooks/block-npx-tsc.sh" }] } }
#
# Why: `npx tsc` runs from the repo root, ignoring the engine's tsconfig.json
# path. The repo script ensures tsc runs from the correct directory.

# Fail open: this hook should only block the explicit bare `npx tsc` pattern.
# Missing dependencies or malformed hook input must not block unrelated Bash use.

if ! command -v jq &>/dev/null; then
  exit 0
fi

if [[ -t 0 ]]; then
  exit 0
fi

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
if [[ -z "$COMMAND" ]]; then
  exit 0
fi
FIRST_WORD=$(echo "$COMMAND" | awk '{print $1}')

if [[ "$FIRST_WORD" = "npx" ]] && echo "$COMMAND" | head -1 | grep -qE 'npx\s+tsc(\s|$)'; then
  echo 'Use the repo typecheck script instead of `npx tsc` (for example, `pnpm run typecheck`)' >&2
  exit 2
fi
