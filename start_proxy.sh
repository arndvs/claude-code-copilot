#!/usr/bin/env bash
set -euo pipefail

# Resolve script directory so .env and config are found regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env if present
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091  # .env is user-supplied at runtime; not available at lint time
  source "$SCRIPT_DIR/.env"
  set +a
fi

PORT="${LITELLM_PORT:-4000}"

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  echo "❌ LITELLM_MASTER_KEY not set. Run 'make setup' or create .env first."
  exit 1
fi

echo "Starting LiteLLM proxy (OpenRouter primary, GitHub Copilot fallback) on port ${PORT}..."
echo ""
echo "After the proxy starts, configure Claude Code:"
echo ""
echo "  make claude-enable"
echo ""
echo "  — or manually set these env vars:"
echo ""
echo "  ANTHROPIC_BASE_URL=http://localhost:${PORT}"
echo "  ANTHROPIC_AUTH_TOKEN=<set to your LITELLM_MASTER_KEY>"
echo "  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1"
echo ""

# Single-source LiteLLM version from .litellm-version (refs #126) so a bump
# updates Docker, Makefile, and this script together.
LITELLM_VERSION="$(cat "$SCRIPT_DIR/.litellm-version" 2>/dev/null || echo '')"
if [ -z "$LITELLM_VERSION" ]; then
  echo "❌ Could not read LiteLLM version from $SCRIPT_DIR/.litellm-version" >&2
  echo "   Create it (e.g. 'echo 1.89.1 > .litellm-version') before starting." >&2
  exit 1
fi

UV_NATIVE_TLS="${UV_NATIVE_TLS:-true}" \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
  exec uv run \
  --with "litellm[proxy]==${LITELLM_VERSION}" \
  litellm --config "$SCRIPT_DIR/litellm_config.yaml" --port "${PORT}"
