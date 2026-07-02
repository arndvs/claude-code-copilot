#!/usr/bin/env bash
#
# Hermetic tests for scripts/probe_completion.sh.
#
# Stubs `curl` via PATH shimming so the retry/classify logic runs offline with
# no network access (same approach as scripts/test_security.sh). The stub writes
# a canned response body to curl's `-o` target and echoes a canned HTTP code
# (mimicking `curl -w '%{http_code}'`). The script's real python3 JSON parsing
# then classifies the stubbed response, so this exercises the actual logic.
#
# Covers the five classification cases from issue #78 — hard-error
# (401/403/400/5xx/000), empty-content, non-JSON 200, success, retry exhaustion —
# plus guard-rail cases: misconfiguration, non-numeric inputs, JSON escaping, retries=0.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

TMPDIR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/probe-test-XXXXXX")
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# --- stub curl: write $STUB_BODY to the -o target, echo $STUB_HTTP_CODE ---------
STUB_DIR="$TMPDIR_ROOT/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
out=""
data=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  [ "$prev" = "-d" ] && data="$arg"
  prev="$arg"
done
[ -n "$out" ] && printf '%s' "${STUB_BODY:-}" > "$out"
[ -n "${STUB_PAYLOAD_FILE:-}" ] && printf '%s' "$data" > "$STUB_PAYLOAD_FILE"
printf '%s' "${STUB_HTTP_CODE:-200}"
STUB
chmod +x "$STUB_DIR/curl"

# run_probe <http_code> <body> — prints the script's resulting status value.
# Retry interval 0 keeps the suite fast; 3 retries is enough to exercise
# empty-content and retry-exhaustion paths.
run_probe() {
  local code="$1" body="$2"
  STUB_HTTP_CODE="$code" STUB_BODY="$body" \
  PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="stub-token" PROBE_MODEL="claude-sonnet-4-6" \
  PROBE_MAX_RETRIES=3 PROBE_RETRY_INTERVAL=0 \
  PATH="$STUB_DIR:$PATH" bash scripts/probe_completion.sh 2>/dev/null \
    | sed -n 's/^status=//p'
}

echo "probe_completion.sh classification tests"
echo "════════════════════════════════════════"

# 1. Success — 200 with content.
s=$(run_probe 200 '{"content":[{"type":"text","text":"pong"}]}')
[ "$s" = "ok" ] && pass "200 with content → ok" || fail "200 with content → expected ok, got '$s'"

# 2. Empty content — 200 with empty content list → degraded after retries.
s=$(run_probe 200 '{"content":[]}')
[ "$s" = "degraded" ] && pass "200 empty content → degraded" || fail "200 empty content → expected degraded, got '$s'"

# 3. Non-JSON 200 — the class that broke once and model-health silently missed.
s=$(run_probe 200 'this is not json at all')
[ "$s" = "fail" ] && pass "200 non-JSON body → fail" || fail "200 non-JSON body → expected fail, got '$s'"

# 4. Hard errors — auth, bad request, unreachable, upstream 5xx.
for code in 401 403 400 500 502 000; do
  s=$(run_probe "$code" '{"error":{"type":"some_error"}}')
  [ "$s" = "fail" ] && pass "HTTP $code → fail" || fail "HTTP $code → expected fail, got '$s'"
done

# 5. Retry exhaustion — a persistent non-hard, non-200 (e.g. 429) exhausts retries → fail.
s=$(run_probe 429 '{"error":{"type":"rate_limited"}}')
[ "$s" = "fail" ] && pass "persistent 429 → fail (retry exhaustion)" || fail "persistent 429 → expected fail, got '$s'"

# 6. Misconfiguration — missing model is a loud fail, not a silent pass.
s=$(STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"text":"x"}]}' \
    PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL="" \
    PATH="$STUB_DIR:$PATH" bash scripts/probe_completion.sh 2>/dev/null | sed -n 's/^status=//p')
[ "$s" = "fail" ] && pass "missing PROBE_MODEL → fail" || fail "missing PROBE_MODEL → expected fail, got '$s'"

# 7. Non-numeric numeric inputs must fall back to defaults, not crash (always-exits-0).
s=$(STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"type":"text","text":"pong"}]}' \
    PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL="m" \
    PROBE_MAX_RETRIES=abc PROBE_RETRY_INTERVAL=xyz PROBE_MAX_TOKENS=nan PROBE_CURL_TIMEOUT=zzz \
    PATH="$STUB_DIR:$PATH" bash scripts/probe_completion.sh 2>/dev/null | sed -n 's/^status=//p')
[ "$s" = "ok" ] && pass "non-numeric inputs → fall back, no crash" || fail "non-numeric inputs → expected ok, got '$s'"

# 8. The request body must be valid JSON even with quotes/backslashes in model/prompt.
PF="$TMPDIR_ROOT/payload.json"
STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"text":"x"}]}' STUB_PAYLOAD_FILE="$PF" \
  PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL='m"x\y' PROBE_PROMPT='say "hi"' \
  PROBE_MAX_RETRIES=1 PATH="$STUB_DIR:$PATH" bash scripts/probe_completion.sh >/dev/null 2>&1
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PF" 2>/dev/null; then
  pass "request body is valid JSON with special chars in model/prompt"
else
  fail "request body is not valid JSON with special chars"
fi

# 9. retries=0 must not crash (arithmetic loop is safe; seq would exit 1).
s=$(STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"type":"text","text":"pong"}]}' \
    PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL="m" \
    PROBE_MAX_RETRIES=0 PATH="$STUB_DIR:$PATH" bash scripts/probe_completion.sh 2>/dev/null | sed -n 's/^status=//p')
[ "$s" = "fail" ] && pass "retries=0 → fail, no crash" || fail "retries=0 → expected fail, got '$s'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
