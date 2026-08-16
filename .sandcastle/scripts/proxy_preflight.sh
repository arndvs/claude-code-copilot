#!/usr/bin/env bash
# Lightweight proxy gate for agent workflows.
#
# Emits should_run=true|false to GITHUB_OUTPUT. This script intentionally does
# not create issues; the central scheduled proxy canary owns proxy incidents.

set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"
python_bin="${PYTHON_BIN:-}"
if [[ -z "$python_bin" ]]; then
    python_bin="$(command -v python3 || command -v python || true)"
fi

emit() {
    local should_run="$1" reason="$2" detail="$3"
    {
        echo "should_run=$should_run"
        echo "reason=$reason"
        echo "detail=$detail"
    } >> "$out"
}

base="${ANTHROPIC_BASE_URL:-}"
token="${ANTHROPIC_AUTH_TOKEN:-}"
api_key="${ANTHROPIC_API_KEY:-}"
config_path="${SANDCASTLE_CONFIG_PATH:-sandcastle.config.json}"

proxy_enabled="$("$python_bin" - <<'PY' 2>/dev/null || echo "true"
import json
import os

try:
    with open(os.environ.get("SANDCASTLE_CONFIG_PATH") or "sandcastle.config.json", encoding="utf-8") as handle:
        config = json.load(handle)
except Exception:
    print("true", end="")
else:
    print("false" if config.get("proxy") is False else "true", end="")
PY
)"

if [[ "$proxy_enabled" == "false" ]]; then
    if [[ -z "$api_key" ]]; then
        echo "::warning::Proxy preflight: direct provider mode missing ANTHROPIC_API_KEY; skipping agent run."
        emit "false" "missing-direct-provider-key" "ANTHROPIC_API_KEY is not configured"
        exit 0
    fi
    echo "Proxy preflight: direct provider mode; running agent."
    emit "true" "direct-provider" "$config_path proxy=false"
    exit 0
fi

if [[ -z "$base" ]]; then
    echo "::warning::Proxy preflight: proxy mode missing base URL; skipping agent run."
    emit "false" "missing-proxy-base-url" "ANTHROPIC_BASE_URL is not configured"
    exit 0
fi

if [[ -z "$token" ]]; then
    echo "::warning::Proxy preflight: missing proxy auth token; skipping agent run."
    emit "false" "missing-proxy-token" "ANTHROPIC_AUTH_TOKEN is not configured"
    exit 0
fi

base="${base%/}"
base="${base%/v1}"

model="$("$python_bin" - <<'PY' 2>/dev/null || echo "claude-opus-4-6"
import json
import os

try:
    with open(os.environ.get("SANDCASTLE_CONFIG_PATH") or "sandcastle.config.json", encoding="utf-8") as handle:
        config = json.load(handle)
except Exception:
    print("claude-opus-4-6", end="")
else:
    print(config.get("model") or "claude-opus-4-6", end="")
PY
)"

ready_body="$(mktemp)"
models_body="$(mktemp)"
trap 'rm -f "$ready_body" "$models_body"' EXIT

ready_code="$(curl -sS -o "$ready_body" -w '%{http_code}' --connect-timeout 5 --max-time 10 "$base/health/readiness" 2>/dev/null || true)"
if [[ "$ready_code" != "200" ]]; then
    echo "::warning::Proxy preflight: readiness returned HTTP ${ready_code:-000}; skipping agent run."
    emit "false" "proxy-not-ready" "readiness returned HTTP ${ready_code:-000}"
    exit 0
fi

models_code="$(curl -sS -o "$models_body" -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $token" "$base/v1/models" 2>/dev/null || true)"

case "$models_code" in
    200)
        if MODEL="$model" MODELS_BODY="$models_body" "$python_bin" - <<'PY' 2>/dev/null
import json
import os
import sys

model = os.environ["MODEL"]
with open(os.environ["MODELS_BODY"], encoding="utf-8") as handle:
    body = json.load(handle)
ids = [item.get("id") for item in body.get("data", []) if isinstance(item, dict) and item.get("id")]
sys.exit(0 if model in ids else 1)
PY
        then
            echo "Proxy preflight: proxy ready and model '$model' is available."
            emit "true" "ok" "proxy ready and model available"
        else
            echo "::warning::Proxy preflight: model '$model' not returned by /v1/models; skipping agent run."
            emit "false" "model-unavailable" "model not returned by /v1/models"
        fi
        ;;
    401|403)
        echo "::warning::Proxy preflight: /v1/models returned HTTP $models_code; skipping agent run."
        emit "false" "proxy-auth-failed" "/v1/models returned HTTP $models_code"
        ;;
    *)
        echo "::warning::Proxy preflight: /v1/models returned HTTP ${models_code:-000}; readiness passed, so running agent."
        emit "true" "models-probe-unavailable" "/v1/models returned HTTP ${models_code:-000}"
        ;;
esac
