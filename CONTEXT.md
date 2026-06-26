# CONTEXT.md — claude-code-copilot

## 1. LiteLLM → Copilot routing

LiteLLM translates Anthropic Messages API calls into GitHub Copilot API calls.
`litellm_config.yaml` maps Claude Code's hyphenated model names to Copilot's dotted names.

| Alias (Claude Code sends) | Target (Copilot receives) |
|---|---|
| `claude-sonnet-4-6` | `github_copilot/claude-opus-4.8` |
| `claude-haiku-4-5-20251001` | `github_copilot/claude-opus-4.8` (Copilot has no Haiku) |
| `claude-opus-4-6` | `github_copilot/claude-opus-4.6` |
| `claude-opus-4-7` | `github_copilot/claude-opus-4.7` |
| `*` (wildcard) | `github_copilot/*` — catch-all pass-through |

Every model entry carries four required editor headers that Copilot validates:

| Header | Value |
|---|---|
| `Editor-Version` | `vscode/1.106.3` |
| `Editor-Plugin-Version` | `copilot/1.388.0` |
| `Copilot-Integration-Id` | `vscode-chat` |
| `User-Agent` | `GithubCopilot/1.388.0` |

**Auth boundary.** `general_settings.master_key` reads from `LITELLM_MASTER_KEY` env var. Claude Code authenticates to LiteLLM with this key; LiteLLM authenticates to Copilot with the OAuth token cached at `~/.config/litellm/github_copilot/`. The two credentials never cross.

**Proxy settings.** `drop_params: true` and `additional_drop_params: ["response_format", "thinking"]` are global `litellm_settings` that silently strip parameters Copilot doesn't support. `stream: true` is set in `litellm_params` on every route to reduce empty-content 200s from the Anthropic adapter — streaming delivers chunks incrementally and avoids the adapter race where a non-streamed response can return empty content.

## 2. DB-less default mode

`docker-compose.yml` runs proxy-only — no database, no extra containers.

| Aspect | Detail |
|---|---|
| Port binding | `127.0.0.1:${LITELLM_PORT:-4000}:4000` — localhost only |
| Cost map | `LITELLM_LOCAL_MODEL_COST_MAP=true` — no remote fetch |
| Healthcheck | `GET /health/readiness` every 30 s |
| Restart | `unless-stopped` |

**Postgres overlay.** `docker-compose.db.yml` adds a `db` service (Postgres 16 Alpine) and sets `DATABASE_URL` on the proxy. Enables spend tracking, virtual keys, and model-in-db.

```
docker compose -f docker-compose.yml -f docker-compose.db.yml up --build
```

> **Rule:** never set `DATABASE_URL` without also starting the db service — LiteLLM enters DB mode with no reachable database and returns `400 "No connected db"` on every request.

## 3. Observability — PROXY_LOG

`litellm_logger.py` is a `CustomLogger` callback registered via `litellm_settings.callbacks`. It emits one `PROXY_LOG` JSON line per completion to stdout.

**Fields logged:**

| Field | Description |
|---|---|
| `model` | Requested model name |
| `call_type` | LiteLLM call type |
| `stream` | Whether the request used streaming (`true`, `false`, or `null` if unknown) |
| `ms` | Latency in milliseconds |
| `finish` | Upstream `finish_reason` / `stop_reason` |
| `content_len` | Text content length (0 = empty, −1 = non-string) |
| `completion_tokens` | Token count from usage |
| `upstream_empty` | `true` when status=success and (content_len=0 or completion_tokens=0) |
| `http_status` | HTTP status code from upstream (int or null) |
| `ratelimit` | Dict of `x-ratelimit-*` headers (prefix-stripped); **omitted** when none present |
| `status` | `success` or `failure` |

**Design rules:**

- **Metadata only** — never logs message content. Safe for production.
- **Defensive** — every code path is wrapped in `try/except`. A logging failure degrades to a no-op; it never raises and never affects request handling.
- **Why it exists** — empty `/v1/messages` completions were traced to LiteLLM's Anthropic-translation adapter. The `upstream_empty` flag lets operators confirm whether the upstream actually returned content when a client sees an empty response.

## 4. CI workflows

Three workflows under `.github/workflows/`:

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push to `dev`/`main`, all PRs | Security tests (`test_security.sh`), YAML parse, compose config validation (base + db overlay), Docker build, ShellCheck |
| `proxy-canary.yml` | every 30 min (`*/30 * * * *`) + manual | Probes hosted proxy: readiness check then a real `/v1/messages` completion. Hard failures (auth/5xx/unreachable) → opens issue. Empty content after retries → **warning, not failure** (transient Copilot quirk) |
| `model-health.yml` | daily 13:00 UTC + manual | Extracts every explicit alias from `litellm_config.yaml`, sends a completion through the proxy for each. Failing aliases → auto-opens/updates a `model-health` issue |

**Proxy-canary detail.** Retries up to 5 times with 6 s sleep between attempts. Distinguishes hard errors (401/403/400/5xx/unreachable) from the Copilot empty-content quirk. On persistent empty content the job sets `status=degraded` and emits a GitHub Actions warning — the proxy is verified as up and authenticating, so it does not page.

**Model-health detail.** Parses `litellm_config.yaml` with PyYAML to extract all non-wildcard aliases. Each alias is probed with 5 retries (4 s apart). Failing aliases are collected and reported in a `model-health` labeled issue. Guards against false greens: if YAML parsing yields zero aliases, the job fails immediately.

## 5. Version endpoint — `/health/version`

Single canonical module: **`health_version.py`**. Registered as a LiteLLM callback via `litellm_config.yaml`; at import time it attaches a `custom_api_router` to the proxy's FastAPI app.

**Environment variables:**

| Variable | Source | Behaviour |
|---|---|---|
| `BUILD_SHA` | `docker build --build-arg BUILD_SHA=$(git rev-parse --short HEAD)` | 7-char SHA; trimmed if longer |
| `BUILD_TIMESTAMP` | `docker build --build-arg BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)` | ISO 8601 UTC string |

**Fallback for local dev.** When `BUILD_SHA` is unset or `"unknown"` (i.e. `make start` without `--build-arg`), the module calls `git rev-parse --short HEAD` so local dev always returns the real working-tree SHA instead of the literal string `"unknown"`.

**Response shape** (no auth required, same as `/health/readiness`):

```json
{"sha": "abc1234", "built_at": "2024-06-01T12:00:00Z"}
```

**Design constraints:**
- Only one module may register `/health/version`. `TestSingleRouteRegistration` in `tests/test_health_version.py` enforces this as a permanent regression guard.
- `version_endpoint.py` was deleted (refs #67); `LITELLM_WORKER_STARTUP_HOOKS` is not used.
