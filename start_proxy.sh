#!/usr/bin/env bash
set -euo pipefail

# Load .env if present
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

PORT="${LITELLM_PORT:-4000}"

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  echo "❌ LITELLM_MASTER_KEY not set. Run 'make setup' or create .env first."
  exit 1
fi

echo "Starting LiteLLM → GitHub Copilot proxy on port ${PORT}..."
echo ""
echo "After the proxy starts, configure Claude Code:"
echo ""
echo "  make claude-enable"
echo ""
echo "  — or manually set these env vars:"
echo ""
echo "  ANTHROPIC_BASE_URL=http://localhost:${PORT}"
echo "  ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}"
echo "  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1"
echo ""

UV_NATIVE_TLS=true exec uv run \
  --with "litellm[proxy]" \
  litellm --config litellm_config.yaml --port "${PORT}"
