#!/usr/bin/env bash
#
# probe_completion.sh — probe a single model for a real completion through the
# proxy and classify the outcome as ok / degraded / fail.
#
# Shared by .github/workflows/proxy-canary.yml (maps degraded -> warn, no page)
# and .github/workflows/model-health.yml (maps degraded -> broken). Encapsulates
# the retry loop, curl construction, JSON parsing, and hard-error vs
# empty-content classification — INCLUDING the non-JSON-200 detection that
# previously lived only in proxy-canary (model-health silently lacked it).
#
# The script ALWAYS exits 0 and reports the outcome via output variables, so a
# caller can distinguish "the probe says fail" (status=fail) from "the probe
# script itself crashed" (non-zero exit).
#
# Inputs (environment variables):
#   PROBE_BASE_URL        required  proxy base URL (a trailing slash is stripped)
#   PROBE_AUTH_TOKEN      required  bearer token for Authorization
#   PROBE_MODEL           required  model name / alias to probe
#   PROBE_MAX_RETRIES     optional  attempts before giving up          (default 5)
#   PROBE_RETRY_INTERVAL  optional  seconds to sleep between attempts   (default 6)
#   PROBE_PROMPT          optional  user prompt      (default "reply with the single word: pong")
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

body_file="${PROBE_RESPONSE_FILE:-}"
if [ -z "$body_file" ]; then
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT
fi

status=""
detail=""
http_code="000"

emit() {
  printf 'status=%s\n' "$status"
  printf 'detail=%s\n' "$detail"
  printf 'http_code=%s\n' "$http_code"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf 'status=%s\n' "$status"
      printf 'detail=%s\n' "$detail"
      printf 'http_code=%s\n' "$http_code"
    } >> "$GITHUB_OUTPUT"
  fi
}

# A missing required input is a misconfiguration (fail loud), not a probe verdict.
if [ -z "$base" ] || [ -z "$token" ] || [ -z "$model" ]; then
  log "❌ probe_completion: PROBE_BASE_URL, PROBE_AUTH_TOKEN, and PROBE_MODEL are all required"
  status="fail"
  detail="probe misconfigured: base URL, auth token, and model are all required"
  emit
  exit 0
fi

got=no
hard=""
empty_seen=no

for i in $(seq 1 "$retries"); do
  http_code=$(curl -s -o "$body_file" -w '%{http_code}' --max-time "$curl_timeout" -X POST "$base/v1/messages" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$model\",\"max_tokens\":$max_tokens,\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}]}" \
    || true)
  # Feed the body via stdin redirection (bash resolves the path) rather than
  # interpolating $body_file into the python source — portable and injection-safe.
  etype=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('error',{}).get('type',''))" < "$body_file" 2>/dev/null || true)
  case "$http_code" in
    200)
      # A non-JSON 200 on /v1/messages is a hard proxy/upstream bug, not the
      # transient empty-content quirk — fail on it instead of masking as degraded.
      if ! python3 -c "import json,sys; json.load(sys.stdin)" < "$body_file" 2>/dev/null; then
        hard="200 but response body was not valid JSON — proxy/upstream serving malformed completions"
        break
      fi
      has=$(python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('content') else 'no')" < "$body_file" 2>/dev/null || echo no)
      if [ "$has" = "yes" ]; then
        got=yes
        log "completion attempt $i/$retries: 200 with content ✓"
        break
      fi
      empty_seen=yes
      log "completion attempt $i/$retries: 200 but empty content — retrying"
      ;;
    401 | 403) hard="auth error HTTP $http_code${etype:+ (type=$etype)} — master key likely wrong/mismatched"; break ;;
    400)       hard="HTTP 400${etype:+ (type=$etype)} — e.g. no_db_connection / bad request"; break ;;
    000)       hard="connection failed — proxy unreachable"; break ;;
    5*)        hard="upstream HTTP $http_code${etype:+ (type=$etype)}"; break ;;
    *)         log "completion attempt $i/$retries: HTTP $http_code — retrying" ;;
  esac
  # Skip the sleep after the final attempt — nothing follows it.
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
else
  status="fail"
  detail="persistent non-200/non-hard responses across $retries retries — proxy not serving completions"
fi

emit
exit 0
