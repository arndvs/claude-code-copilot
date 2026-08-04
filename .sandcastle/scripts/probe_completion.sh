#!/usr/bin/env bash
#
# probe_completion.sh — probe a single model for a real completion through the
# proxy and classify the outcome as ok / degraded / fail.
#
# Shared by .github/workflows/proxy-canary.yml. Encapsulates the retry loop,
# curl construction, JSON parsing, SSE detection, and hard-error vs
# empty-content classification.
#
# The script ALWAYS exits 0 and reports the outcome via output variables, so a
# caller can distinguish "the probe says fail" (status=fail) from "the probe
# script itself crashed" (non-zero exit).
#
# Inputs (environment variables):
#   PROBE_BASE_URL        required  proxy base URL (trailing slash stripped)
#   PROBE_AUTH_TOKEN      required  bearer token for Authorization
#   PROBE_MODEL           required  model name / alias to probe
#   PROBE_MAX_RETRIES     optional  attempts before giving up            (default 5)
#   PROBE_RETRY_INTERVAL  optional  seconds to sleep between attempts   (default 6)
#   PROBE_PROMPT          optional  user prompt  (default "reply with the single word: pong")
#   PROBE_MAX_TOKENS      optional  max_tokens in the request           (default 64)
#   PROBE_CURL_TIMEOUT    optional  curl --max-time seconds per attempt (default 60)
#   PROBE_RESPONSE_FILE   optional  where the response body is written  (default: mktemp)
#
# Outputs (printed to stdout as key=value lines, and appended to $GITHUB_OUTPUT
# when that variable is set):
#   status=ok|degraded|fail
#   detail=<human-readable explanation>
#   http_code=<last HTTP status observed>
#
# Progress/diagnostic lines go to stderr so stdout stays a clean key=value block.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

base="${PROBE_BASE_URL:-}"
base="${base%/}"
token="${PROBE_AUTH_TOKEN:-}"
model="${PROBE_MODEL:-}"
retries="${PROBE_MAX_RETRIES:-5}"
interval="${PROBE_RETRY_INTERVAL:-6}"
prompt="${PROBE_PROMPT:-reply with the single word: pong}"
max_tokens="${PROBE_MAX_TOKENS:-64}"
curl_timeout="${PROBE_CURL_TIMEOUT:-60}"

# Numeric inputs must be integers — a non-numeric value would crash the arithmetic
# loop or curl under set -e and break the "always exits 0" contract.
is_int() { case "${1:-}" in "" | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_int "$retries"      || retries=5
is_int "$interval"     || interval=6
is_int "$max_tokens"   || max_tokens=64
is_int "$curl_timeout" || curl_timeout=60

status=""
detail=""
http_code="000"

sanitize_output_value() {
  local value="${1:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

emit() {
  local safe_status safe_detail safe_http_code
  safe_status="$(sanitize_output_value "$status")"
  safe_detail="$(sanitize_output_value "$detail")"
  safe_http_code="$(sanitize_output_value "$http_code")"
  printf 'status=%s\n'   "$safe_status"
  printf 'detail=%s\n'   "$safe_detail"
  printf 'http_code=%s\n' "$safe_http_code"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf 'status=%s\n'   "$safe_status"
      printf 'detail=%s\n'   "$safe_detail"
      printf 'http_code=%s\n' "$safe_http_code"
    } >> "$GITHUB_OUTPUT"
  fi
}

# Allocate the response file after emit is defined so a mktemp failure is a fail
# verdict, not a non-zero crash under set -e.
body_file="${PROBE_RESPONSE_FILE:-}"
if [ -z "$body_file" ]; then
  if ! body_file="$(mktemp 2>/dev/null)"; then
    status="fail"
    detail="could not allocate a temp file for the response body"
    emit
    exit 0
  fi
  trap 'rm -f "$body_file"' EXIT
fi

# A missing required input is a misconfiguration (fail loud), not a probe verdict.
if [ -z "$base" ] || [ -z "$token" ] || [ -z "$model" ]; then
  log "❌ probe_completion: PROBE_BASE_URL, PROBE_AUTH_TOKEN, and PROBE_MODEL are all required"
  status="fail"
  detail="probe misconfigured: base URL, auth token, and model are all required"
  emit
  exit 0
fi

# Dependency + response-file writability preflight.
for dep in curl python3; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    status="fail"
    detail="required command not found: $dep"
    emit
    exit 0
  fi
done
if ! : > "$body_file" 2>/dev/null; then
  status="fail"
  detail="response file is not writable: $body_file"
  emit
  exit 0
fi

got=no
hard=""
empty_seen=no

# Build the request body with python3 so a model/prompt containing quotes,
# backslashes, or newlines cannot produce invalid JSON.
if ! payload=$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"max_tokens":int(sys.argv[2]),"messages":[{"role":"user","content":sys.argv[3]}]}))' \
    "$model" "$max_tokens" "$prompt" 2>/dev/null); then
  status="fail"
  detail="could not build the request payload (python3 error)"
  emit
  exit 0
fi

# Locate the shared probe_parser module (repo-root scripts/).
PROBE_PARSER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/probe_parser.py"

# Bash arithmetic loop (not seq) — safe for retries=0.
for ((i = 1; i <= retries; i++)); do
  http_code=$(curl -s -o "$body_file" -w '%{http_code}' --max-time "$curl_timeout" \
    -X POST "$base/v1/messages" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$payload" \
    || true)
  [ -n "$http_code" ] || http_code="000"

  # Classify the response via the shared probe_parser module (refs #112).
  # Outputs: status=yes|no, format=sse|json|unknown, hard=true|false, detail=...
  classification=$(python3 "$PROBE_PARSER" "$http_code" < "$body_file" 2>/dev/null || true)
  has=$(printf '%s\n' "$classification" | sed -n 's/^status=//p')
  fmt=$(printf '%s\n' "$classification" | sed -n 's/^format=//p')
  is_hard=$(printf '%s\n' "$classification" | sed -n 's/^hard=//p')
  hard_detail=$(printf '%s\n' "$classification" | sed -n 's/^detail=//p')

  if [ "$is_hard" = "true" ]; then
    hard="$hard_detail"
    break
  fi

  case "$http_code" in
    200)
      if [ "$fmt" = "sse" ]; then
        [ "$has" = "yes" ] && log "completion attempt $i/$retries: 200 SSE with content ✓" \
                           || log "completion attempt $i/$retries: 200 SSE — empty content"
      else
        [ "$has" = "yes" ] && log "completion attempt $i/$retries: 200 JSON with content ✓" \
                           || log "completion attempt $i/$retries: 200 JSON — empty content"
      fi
      if [ "$has" = "yes" ]; then
        got=yes
        break
      fi
      empty_seen=yes
      ;;
    *) log "completion attempt $i/$retries: HTTP $http_code — retrying" ;;
  esac
  if [ "$i" -lt "$retries" ]; then
    sleep "$interval"
  fi
done

if [ -n "$hard" ]; then
  status="fail"
  detail="$hard"
elif [ "$got" = "yes" ]; then
  status="ok"
  detail="completion succeeded"
elif [ "$empty_seen" = "yes" ]; then
  status="degraded"
  detail="proxy up and authenticating, but upstream returned empty completions across $retries retries"
elif [ "$retries" -eq 0 ]; then
  status="fail"
  detail="no probe attempts made (PROBE_MAX_RETRIES=0)"
else
  status="fail"
  detail="persistent non-200/non-hard responses across $retries retries — proxy not serving completions"
fi

emit
exit 0
