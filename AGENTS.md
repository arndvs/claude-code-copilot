# AGENTS.md — claude-code-copilot

## Security

**NEVER read `.env` or any file matching `.env.*`.** These contain secrets.

## Architecture

LiteLLM proxy translates Anthropic Messages API → GitHub Copilot API.

```
Claude Code  →  LiteLLM (:4000)  →  api.githubcopilot.com
                 ↑ litellm_config.yaml
                 ↑ OAuth token cached at ~/.config/litellm/github_copilot/
```

## Key files

| File | Purpose |
|------|---------|
| `litellm_config.yaml` | Proxy routing config — wildcard → `github_copilot/*` |
| `Makefile` | Workflow automation (setup/start/stop/test/enable/disable) |
| `start_proxy.sh` | Standalone proxy launcher with `.env` loading |
| `scripts/claude_enable.py` | Write proxy env vars to `~/.claude/settings.json` |
| `scripts/claude_disable.py` | Remove proxy config from Claude settings |
| `scripts/list-copilot-models.sh` | Query available Copilot models |
| `.env.example` | Template for required environment variables |

## Conventions

- Shell scripts use `bash` with `set -euo pipefail`
- Python scripts are standalone (no dependencies beyond stdlib)
- Port default: `4000` (override via `LITELLM_PORT` or `make start PORT=XXXX`)
- `UV_NATIVE_TLS=true` is required for corporate proxy / SSL environments
- `LITELLM_LOCAL_MODEL_COST_MAP=true` avoids remote cost map fetch
