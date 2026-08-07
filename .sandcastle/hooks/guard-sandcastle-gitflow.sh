#!/bin/bash
set -euo pipefail

# guard-sandcastle-gitflow.sh — Claude Code hook that blocks committing
# Sandcastle infrastructure changes directly to the default/production branch
# (main) without first landing them on the integration branch (dev).
#
# Install as a PreToolUse hook in .claude/settings.json:
#   { "hooks": { "PreToolUse": [{ "matcher": "Bash", "command": ".sandcastle/hooks/guard-sandcastle-gitflow.sh" }] } }
#
# Why: Sandcastle workflows checkout the integration branch (dev) and run
# vendored scripts from .sandcastle/. If infra changes (scripts, workflows,
# engine) land only on main, the dev branch drifts and workflows fail with
# "No such file or directory" (the proxy_preflight.sh incident). Infra changes
# must flow feature -> dev -> main.

# Fail open: only block the explicit pattern of committing infra files to main.
# Missing git context or malformed input must not block unrelated Bash use.

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

# Only guard git commit / git add operations
FIRST_WORD=$(echo "$COMMAND" | awk '{print $1}')
if [[ "$FIRST_WORD" != "git" ]]; then
  exit 0
fi

# Determine current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ -z "$CURRENT_BRANCH" || "$CURRENT_BRANCH" == "HEAD" ]]; then
  exit 0
fi

# Only guard commits on the production branch (main). Feature/dev branches are fine.
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  exit 0
fi

# Check if the command touches sandcastle infra paths
if echo "$COMMAND" | grep -qE '\.sandcastle/|\.github/workflows/agent-|\.github/workflows/sandcastle-ci|\.github/workflows/labels-sync|\.github/actions/sandcastle'; then
  echo "Sandcastle infrastructure change detected on branch 'main'." >&2
  echo "Sandcastle infra (scripts, workflows, engine, actions) must flow feature -> dev -> main." >&2
  echo "Commit to a feature branch and merge into 'dev' first, then 'dev' into 'main'." >&2
  echo "This prevents the dev branch from drifting (the proxy_preflight.sh incident)." >&2
  exit 2
fi

exit 0
