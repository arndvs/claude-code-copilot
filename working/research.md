# Research: Claude Code ↔ GitHub Copilot Proxy

> **⚠️ Historical document** — Written during initial audit (2026-05-20) before
> scaffolding was completed. Many issues described below (wrong config, missing
> files, script paths) have since been resolved. Kept for reference.

Generated: 2026-05-20
Topic: Deep audit of claude-code-copilot repo, comparison with reference implementations, shft integration path

## Summary

The repo has a solid README and Makefile, but **the config file is wrong** — `litellm_config.yaml` routes to Azure OpenAI, not GitHub Copilot. The README describes Copilot routing that doesn't match the actual config. The Makefile references scripts at `scripts/claude_enable.py` but the files live at root level (`claude_enable.py`). There's no root `.gitignore`, no `AGENTS.md`, no Copilot-specific config file, no `start_proxy.sh`, no `Dockerfile`, and no `docker-compose.yml` at root. The repo is a good README wrapped around the wrong config.

The two reference implementations (NBB's litellm-claude-code-proxy, kjetiljd's claude-code-over-github-copilot) are both working and solve different problems. NBB routes Claude Code → Azure AI Foundry. kjetiljd routes Claude Code → GitHub Copilot with explicit model entries. Neither has wildcard Copilot routing, Docker Compose, AFK mode docs, or `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` — those are the gaps this repo should fill.

shft (the autonomous agent system) has zero awareness of proxy configuration. It calls `claude` or `srt claude` and relies on whatever Claude Code configuration is active. To route through the proxy, either `~/.claude/settings.json` needs the proxy env vars (via `make claude-enable`) or `secrets.env` needs `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`. Docker networking (`host.docker.internal`) is a consideration for AFK mode running in `srt` containers.

## Architecture

### How it SHOULD work (per README)

```
Claude Code
  → ANTHROPIC_BASE_URL=http://localhost:4000
  → ANTHROPIC_AUTH_TOKEN=<LITELLM_MASTER_KEY>
  → LiteLLM Proxy (port 4000)
    → litellm_config.yaml: model_name: "*" → github_copilot/*
    → extra_headers: editor-version, Copilot-Integration-Id, etc.
    → GitHub Copilot API (api.githubcopilot.com)
    → Cached OAuth token at ~/.config/litellm/github_copilot/access-token
```

### How it ACTUALLY works (current config)

```
Claude Code
  → LiteLLM Proxy (port 4000)
  → litellm_config.yaml: model_name: "*" → AZURE_OPENAI_DEPLOYMENT
  → Azure AI Foundry
  ✗ No Copilot headers, no Copilot routing, no OAuth flow
```

The actual `litellm_config.yaml` is a copy from the NBB repo (Azure-only). It was never updated for Copilot routing.

## Three-Way Comparison

| Feature | This repo (claude-code-copilot) | NBB (litellm-claude-code-proxy) | kjetiljd (claude-code-over-copilot) |
|---|---|---|---|
| **Target provider** | README says Copilot, config says Azure | Azure AI Foundry | GitHub Copilot |
| **Model routing** | Wildcard (in README only) | Wildcard `"*"` (working) | Explicit model entries |
| **Config file** | `litellm_config.yaml` (Azure, broken for Copilot) | `litellm_config.yaml` (Azure, working) | `copilot-config.yaml` (Copilot, working) |
| **Headers** | Documented in README, not in config | None needed (Azure) | `Editor-Version`, `Copilot-Integration-Id` |
| **OAuth** | Mentioned in README, no script | N/A (Azure keys) | Handled by LiteLLM `github_copilot` provider |
| **`drop_params`** | In README fallback example, not in config | Not set | Not set |
| **`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`** | In `claude_enable.py` ✅ | Not set | Not set |
| **Docker** | No Dockerfile at root | Dockerfile + docker-compose.yml ✅ | No Docker |
| **Enable/disable toggle** | `claude_enable.py` / `claude_disable.py` ✅ | Manual (3 options in README) | `scripts/claude_enable.py` / `claude_disable.py` ✅ |
| **Model discovery** | `list-copilot-models.sh` ✅ | N/A | `list-copilot-models.sh` ✅ |
| **Makefile** | Full Makefile ✅ | No Makefile | Makefile (venv-based) |
| **AFK mode docs** | In README ✅ | Not addressed | Not addressed |
| **`.gitignore`** | Missing at root ❌ | `.env` ✅ | `.gitignore` ✅ |
| **`AGENTS.md`** | Missing at root ❌ | ✅ (with security rules) | Not present |
| **`start_proxy.sh`** | Missing at root ❌ | ✅ (with UV_NATIVE_TLS) | Not present |
| **License** | Missing at root ❌ | MIT (NBB) | Not visible |
| **Port** | 4000 | 4000 | 4444 |
| **Package manager** | `uv` | `uv` | `venv` + `pip` |

## Critical Bugs

### 1. litellm_config.yaml routes to Azure, not Copilot
The only config file is the NBB one (`litellm-claude-code-proxy-main/litellm_config.yaml`) which routes `model_name: "*"` to Azure OpenAI. There is no Copilot-routing config file at the root. `make start` runs `litellm --config litellm_config.yaml` — that file doesn't exist at root.

**Fix:** Create a root `litellm_config.yaml` with:
```yaml
litellm_settings:
  drop_params: true

model_list:
  - model_name: "*"
    litellm_params:
      model: "github_copilot/*"
      extra_headers:
        editor-version: "vscode/1.85.1"
        editor-plugin-version: "copilot/1.155.0"
        Copilot-Integration-Id: "vscode-chat"
        user-agent: "GithubCopilot/1.155.0"

general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
```

### 2. Makefile references `scripts/` but scripts are at root
`claude-enable` target calls `python3 scripts/claude_enable.py` — the file is at `./claude_enable.py`. Same for `claude_disable.py`.

**Fix:** Either move scripts to `scripts/` dir or update Makefile paths.

### 3. No root `.gitignore`
`make setup` creates `.env` with `LITELLM_MASTER_KEY`. Without `.gitignore`, this gets committed.

**Fix:** Create `.gitignore` with `.env`, `*.log`, `__pycache__/`.

### 4. No root `start_proxy.sh`
README mentions `./start_proxy.sh` but it only exists in `litellm-claude-code-proxy-main/`. The Makefile's `start` target duplicates this logic inline.

**Fix:** Create `start_proxy.sh` at root or remove references from README.

### 5. No root Dockerfile or docker-compose.yml
Docker section in README references `docker build -t claude-code-copilot .` but there's no Dockerfile at root.

**Fix:** Create root Dockerfile and docker-compose.yml for the Copilot variant.

### 6. No AGENTS.md / CLAUDE.md at root
AI agents working in the repo get no guidance. NBB's AGENTS.md has the critical "NEVER read .env" rule.

**Fix:** Create root AGENTS.md and CLAUDE.md.

### 7. No LICENSE at root
NBB's MIT license is in the subdir. This repo has no license.

## What kjetiljd Has That We Should Lift

1. **`generate_env.py`** — generates `LITELLM_SALT_KEY` in addition to master key. Salt key is used by LiteLLM for hashing and is important if you later add database/virtual keys. Our `make setup` doesn't generate this.

2. **`ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` in enable script** — kjetiljd sets these to route the "main" and "fast" model slots to specific Copilot models. Our enable script doesn't do this, relying on wildcard routing instead. Both approaches are valid but explicit model assignment gives more control.

3. **`ENABLE_NETWORK_MONITOR=true` and `LOG_LEVEL=DEBUG`** — helpful for debugging first-run issues.

## What NBB Has That We Should Lift

1. **Working config** — their `litellm_config.yaml` actually matches their provider (Azure). Ours doesn't match (says Copilot in README, config is Azure).

2. **AGENTS.md security rules** — "NEVER read the .env file" is a strong pattern for AI agent safety.

3. **`UV_NATIVE_TLS=true`** in `start_proxy.sh` — already in our Makefile, but not in a standalone script.

4. **`LITELLM_LOCAL_MODEL_COST_MAP=true`** — already in our `make setup`. Good.

5. **docker-compose.yml with Postgres** — enables spend tracking, virtual keys, admin UI. We document it but don't have the files.

## shft Integration

### Current state
shft has **zero proxy awareness**. No `ANTHROPIC_BASE_URL`, no `ANTHROPIC_AUTH_TOKEN`, no `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` anywhere in the shft codebase.

### Integration path

**Option A — `~/.claude/settings.json` (simplest)**
Run `make claude-enable` from the proxy repo. Both `shft run` (HITL) and `shft afk` (AFK) pick up settings automatically. Downside: affects ALL Claude Code sessions, not just shft.

**Option B — `secrets.env` injection**
Add to `secrets.env` (loaded by `run-with-secrets.sh`):
```bash
ANTHROPIC_BASE_URL=http://host.docker.internal:4000
ANTHROPIC_AUTH_TOKEN=sk-your-litellm-master-key
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
```
`run-with-secrets.sh` exports these before running `srt claude`, so they flow into the Docker container.

**Option C — per-project `.claude/settings.json`**
Each repo gets a local `.claude/settings.json` with proxy config. Only affects that repo's Claude Code sessions.

### Docker networking issue
AFK mode runs `srt claude` inside Docker. `localhost:4000` on the host is unreachable from inside the container. Must use `host.docker.internal:4000` (Docker Desktop on Mac/Windows) or `--network host` (Linux). This needs to be documented and handled.

### Rate limit concern
Copilot plans allow limited premium requests per month. shft's autonomous loop (up to 5 iterations per `shft afk` run, potentially many runs per day) could exhaust quota in days. The Azure fallback pattern in the README is critical here — but the actual config doesn't implement it.

### Token coexistence
shft mints `GITHUB_TOKEN` per iteration (GitHub App installation token for repo access). The proxy uses `ANTHROPIC_AUTH_TOKEN` (LiteLLM master key). These are independent and don't conflict. Both can coexist in the environment.

### Missing: proxy health check
shft has `validate-env.sh` for pre-flight checks but no check for proxy liveness. If the proxy is down, `srt claude` fails with an unhelpful error. A `curl -sf http://localhost:4000/health/readiness` check would surface this early.

## Open Questions

1. **Should the two reference repos be kept as subdirectories or removed?** They add clutter but serve as reference. Consider moving to a `references/` dir or just linking in README.

2. **Should `make start` also start Docker Compose?** Or keep bare `litellm` as default and Docker as optional?

3. **Copilot rate limits for AFK** — has anyone tested actual limits with the autonomous loop pattern? The blog post author reported mid-month exhaustion with interactive use. AFK would be worse.

4. **Token expiry handling** — when the cached Copilot token expires, the proxy fails silently. Should `start_proxy.sh` check token freshness and re-auth proactively?

5. **Should `claude_enable.py` set `ANTHROPIC_MODEL`?** kjetiljd sets it to `claude-sonnet-4`. With wildcard routing this isn't required, but it gives explicit control over which model Claude Code defaults to.

## Recommendations

### Immediate (before publishing)

1. **Create root `litellm_config.yaml`** with actual GitHub Copilot routing (wildcard + headers + `drop_params`)
2. **Move scripts to `scripts/`** (or fix Makefile paths) — `claude_enable.py`, `claude_disable.py`, `list-copilot-models.sh`
3. **Create root `.gitignore`** — `.env`, `*.log`, `__pycache__/`, `.env.backup*`
4. **Create root `AGENTS.md`** with "NEVER read .env" rule + architecture overview
5. **Create root `CLAUDE.md`** pointing to `AGENTS.md`
6. **Create root `.env.example`** — template with all configurable vars documented
7. **Create root `start_proxy.sh`** — standalone launch script with `UV_NATIVE_TLS=true`
8. **Create root `Dockerfile`** and `docker-compose.yml` — for Copilot variant
9. **Add MIT LICENSE** at root
10. **Move reference repos** to `references/` or delete them and just link in README

### For shft integration

11. **Add proxy vars to `secrets.env` template** — `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`
12. **Use `host.docker.internal`** instead of `localhost` in `ANTHROPIC_BASE_URL` for Docker-based AFK
13. **Add proxy health check** to `validate-env.sh --afk`
14. **Document the integration** in both repos' READMEs

### Later

15. **Azure fallback** — uncomment when Azure quota arrives, add env vars to `.env.example`
16. **Test rate limit boundaries** — quantify how many Copilot requests per shft iteration
17. **Token auto-refresh** — detect expired Copilot tokens and re-trigger OAuth
