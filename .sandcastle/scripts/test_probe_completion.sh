#!/usr/bin/env bash
#
# test_probe_completion.sh — hermetic tests for probe_completion.sh.
#
# Stubs curl via PATH shimming so the retry/classify logic runs offline with
# no network access. The stub writes a canned response body to curl's -o target
# and echoes a canned HTTP code. The real python3 JSON/SSE parsing then
# classifies the stubbed response.
#
# Covers: hard errors, empty-content/degraded, non-JSON 200, SSE content,
# SSE empty, success, retry exhaustion, misconfiguration, non-numeric inputs,
# JSON escaping, retries=0, keep-alive SSE streams, output sanitization.
#
# Usage: bash test_probe_completion.sh  (from any directory)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$SCRIPT_DIR/probe_completion.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$1"; }

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# stub curl: write $STUB_BODY to the -o target, echo $STUB_HTTP_CODE
STUB_DIR="$TMPDIR_ROOT/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  prev="$arg"
done
[ -n "$out" ] && printf '%s' "${STUB_BODY:-}" > "$out"
printf '%s' "${STUB_HTTP_CODE:-200}"
STUB
chmod +x "$STUB_DIR/curl"

# run_probe: run the script with stubbed curl, return the status= value.
# PROBE_RETRY_INTERVAL=0 keeps the suite fast; 3 retries exercises empty-content.
run_probe() {
  local code="$1" body="$2"
  STUB_HTTP_CODE="$code" STUB_BODY="$body" \
  PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="stub-token" PROBE_MODEL="claude-sonnet-4-6" \
  PROBE_MAX_RETRIES=3 PROBE_RETRY_INTERVAL=0 \
  PATH="$STUB_DIR:$PATH" bash "$PROBE" 2>/dev/null \
    | sed -n 's/^status=//p'
}

echo "── probe_completion.sh tests ──"

# ── 1. Success — 200 JSON with content ────────────────────────────────────────
s=$(run_probe 200 '{"content":[{"type":"text","text":"pong"}]}')
[ "$s" = "ok" ] && pass "200 JSON with content → ok" || fail "200 JSON with content: expected ok, got '$s'"

# ── 2. Empty content — degraded after retries ────────────────────────────────
s=$(run_probe 200 '{"content":[]}')
[ "$s" = "degraded" ] && pass "200 empty JSON content → degraded" || fail "200 empty content: expected degraded, got '$s'"

# ── 3. Non-JSON 200 → fail ────────────────────────────────────────────────────
s=$(run_probe 200 'this is not json at all')
[ "$s" = "fail" ] && pass "200 non-JSON, non-SSE body → fail" || fail "200 non-JSON: expected fail, got '$s'"

# ── 4. Hard HTTP errors ───────────────────────────────────────────────────────
for code in 401 403 400 500 502 000; do
  s=$(run_probe "$code" '{"error":{"type":"some_error"}}')
  [ "$s" = "fail" ] && pass "HTTP $code → fail" || fail "HTTP $code: expected fail, got '$s'"
done

# ── 5. Retry exhaustion (429) ─────────────────────────────────────────────────
s=$(run_probe 429 '{"error":{"type":"rate_limited"}}')
[ "$s" = "fail" ] && pass "persistent 429 → fail (retry exhaustion)" || fail "persistent 429: expected fail, got '$s'"

# ── 6. Misconfiguration (missing model) ───────────────────────────────────────
s=$(STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"text":"x"}]}' \
    PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL="" \
    PATH="$STUB_DIR:$PATH" bash "$PROBE" 2>/dev/null | sed -n 's/^status=//p')
[ "$s" = "fail" ] && pass "missing PROBE_MODEL → fail" || fail "missing PROBE_MODEL: expected fail, got '$s'"

# ── 7. Non-numeric inputs fall back, don't crash ─────────────────────────────
s=$(STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"type":"text","text":"pong"}]}' \
    PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL="m" \
    PROBE_MAX_RETRIES=abc PROBE_RETRY_INTERVAL=xyz PROBE_MAX_TOKENS=nan PROBE_CURL_TIMEOUT=zzz \
    PATH="$STUB_DIR:$PATH" bash "$PROBE" 2>/dev/null | sed -n 's/^status=//p')
[ "$s" = "ok" ] && pass "non-numeric inputs → fall back, no crash" || fail "non-numeric inputs: expected ok, got '$s'"

# ── 8. JSON escaping in model/prompt ─────────────────────────────────────────
PF="$TMPDIR_ROOT/payload.json"
cat > "$STUB_DIR/curl" <<'STUB2'
#!/usr/bin/env bash
out=""; prev=""; data=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  [ "$prev" = "-d" ] && data="$arg"
  prev="$arg"
done
[ -n "$out" ] && printf '%s' "${STUB_BODY:-}" > "$out"
[ -n "${STUB_PAYLOAD_FILE:-}" ] && printf '%s' "$data" > "${STUB_PAYLOAD_FILE}"
printf '%s' "${STUB_HTTP_CODE:-200}"
STUB2
chmod +x "$STUB_DIR/curl"
STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"text":"x"}]}' STUB_PAYLOAD_FILE="$PF" \
  PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL='m"x\y' PROBE_PROMPT='say "hi"' \
  PROBE_MAX_RETRIES=1 PATH="$STUB_DIR:$PATH" bash "$PROBE" >/dev/null 2>&1
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PF" 2>/dev/null; then
  pass "request body valid JSON with special chars in model/prompt"
else
  fail "request body not valid JSON with special chars"
fi

# Restore simple stub
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  prev="$arg"
done
[ -n "$out" ] && printf '%s' "${STUB_BODY:-}" > "$out"
printf '%s' "${STUB_HTTP_CODE:-200}"
STUB
chmod +x "$STUB_DIR/curl"

# ── 9. retries=0 → fail, no crash ────────────────────────────────────────────
s=$(STUB_HTTP_CODE=200 STUB_BODY='{"content":[{"type":"text","text":"pong"}]}' \
    PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL="m" \
    PROBE_MAX_RETRIES=0 PATH="$STUB_DIR:$PATH" bash "$PROBE" 2>/dev/null | sed -n 's/^status=//p')
[ "$s" = "fail" ] && pass "retries=0 → fail, no crash" || fail "retries=0: expected fail, got '$s'"

# ── 10. SSE response with content → ok ───────────────────────────────────────
SSE_CONTENT='event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "pong"}}'
s=$(run_probe 200 "$SSE_CONTENT")
[ "$s" = "ok" ] && pass "200 SSE with content_block_delta → ok" || fail "200 SSE with content: expected ok, got '$s'"

# ── 11. SSE response empty (no content deltas) → degraded ────────────────────
SSE_EMPTY='event: message_start
data: {"type": "message_start", "message": {"content": []}}

event: message_stop
data: {"type": "message_stop"}'
s=$(run_probe 200 "$SSE_EMPTY")
[ "$s" = "degraded" ] && pass "200 SSE without content_block_delta → degraded" || fail "200 SSE empty: expected degraded, got '$s'"

# ── 12. SSE stream starting with keep-alive : comment ────────────────────────
SSE_KEEPALIVE=': keep-alive

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "pong"}}'
s=$(run_probe 200 "$SSE_KEEPALIVE")
[ "$s" = "ok" ] && pass "200 SSE starting with : keep-alive → ok" || fail "200 SSE keep-alive: expected ok, got '$s'"

# ── 13. SSE data: without space (valid per SSE spec) ─────────────────────────
SSE_NOSPACE='event: content_block_delta
data:{"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "pong"}}'
s=$(run_probe 200 "$SSE_NOSPACE")
[ "$s" = "ok" ] && pass "200 SSE data: without space → ok" || fail "200 SSE data: no space: expected ok, got '$s'"

# ── 14. Output values sanitize CR/LF before key=value emission ────────────────
out=$(STUB_HTTP_CODE=400 STUB_BODY='{"error":{"type":"bad\nstatus=ok\rhttp_code=200"}}' \
    PROBE_BASE_URL="http://proxy.test" PROBE_AUTH_TOKEN="t" PROBE_MODEL="m" \
    PATH="$STUB_DIR:$PATH" bash "$PROBE" 2>/dev/null)
status_lines=$(printf '%s\n' "$out" | grep -c '^status=' || true)
detail_lines=$(printf '%s\n' "$out" | grep -c '^detail=.*status=ok.*http_code=200' || true)
[ "$status_lines" -eq 1 ] && [ "$detail_lines" -eq 1 ] \
  && pass "CR/LF in upstream error type cannot inject output keys" \
  || fail "CR/LF sanitization: expected one status line and flattened detail, got: $out"

echo ""
printf "  \033[32m%d passed\033[0m  \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
