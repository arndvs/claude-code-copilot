#!/usr/bin/env bash
# _launch_proxy.sh — shared proxy-launch function (refs #115, #127)
#
# Single source of truth for assembling the canonical `uv run` command that
# starts the LiteLLM proxy. Both `Makefile:start` and `start_proxy.sh` source
# this file and call `launch_proxy`, so the command assembly, env requirements,
# and version pin live in exactly one place.
#
# This file is meant to be SOURCED, not executed. It defines `launch_proxy`
# and does not run anything on its own.

# Repo root is the parent of this file's directory (scripts/), resolved from the
# file's own location so it works regardless of cwd or how it is sourced.
_LAUNCH_PROXY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_PROXY_ROOT="$(cd "$_LAUNCH_PROXY_DIR/.." && pwd)"

# launch_proxy [port] [config_path]
#
# Validates LITELLM_MASTER_KEY is set, reads the LiteLLM version from
# .litellm-version, and runs the canonical `uv run` command. Callers choose
# exec-vs-subshell semantics by how they invoke it:
#   - start_proxy.sh:  exec launch_proxy "$PORT" "$CONFIG"   (replaces shell)
#   - Makefile:start:  launch_proxy "$PORT" "$CONFIG"        (stays in subshell)
launch_proxy() {
  local port="${1:-4000}"
  local config_path="${2:-$LAUNCH_PROXY_ROOT/litellm_config.yaml}"

  if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
    echo "❌ LITELLM_MASTER_KEY not set. Run 'make setup' or create .env first." >&2
    return 1
  fi

  local version
  version="$(cat "$LAUNCH_PROXY_ROOT/.litellm-version" 2>/dev/null || echo '')"
  if [[ -z "$version" ]]; then
    echo "❌ Could not read LiteLLM version from $LAUNCH_PROXY_ROOT/.litellm-version" >&2
    echo "   Create it (e.g. 'echo 1.89.1 > .litellm-version') before starting." >&2
    return 1
  fi

  echo "Starting LiteLLM proxy (GitHub Copilot primary, OpenRouter fallback) on port ${port}..."
  echo ""

  UV_NATIVE_TLS="${UV_NATIVE_TLS:-true}" \
    PYTHONPATH="$LAUNCH_PROXY_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
    uv run \
    --with "litellm[proxy]==${version}" \
    litellm --config "${config_path}" --port "${port}"
}
