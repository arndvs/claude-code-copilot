#!/usr/bin/env bash
# test_security.sh — Lightweight security regression checks
#
# Verifies secret-handling fixes without network access or reading the real .env.
# Uses temp directories and fake secrets only.
#
# Usage: bash scripts/test_security.sh

set -euo pipefail

PASS=0
FAIL=0
TMPDIR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sec-test-XXXXXX")
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

run_claude_status() {
    local fake_home="$1"

    if command -v make >/dev/null 2>&1; then
        HOME="$fake_home" PATH="$STATUS_STUB_DIR:$PATH" make -s claude-status
        return
    fi

    # Some Windows Git Bash installs do not include make. In that case, extract
    # and execute the redaction command from the checked-in Makefile target so
    # this test still tracks the implementation instead of copying it.
    HOME="$fake_home" PATH="$STATUS_STUB_DIR:$PATH" python3 - <<'PY'
import os
import re
import subprocess
import sys

in_target = False
redaction_code = None

with open("Makefile", encoding="utf-8") as makefile:
    for raw_line in makefile:
        if not in_target:
            if raw_line.startswith("claude-status:"):
                in_target = True
            continue

        if raw_line.startswith("\t"):
            line = raw_line[1:].rstrip("\n")
            match = re.search(r'python3 -c "(.*)" < ~/', line)
            if match:
                redaction_code = match.group(1)
                break
            continue

        if raw_line.strip() == "":
            break

        break

if redaction_code is None:
    print("claude-status redaction command not found in Makefile", file=sys.stderr)
    sys.exit(1)

settings_file = os.path.join(os.environ["HOME"], ".claude", "settings.json")
try:
    with open(settings_file, encoding="utf-8") as settings:
        settings_json = settings.read()
except FileNotFoundError:
    print("No settings file — using Claude Code defaults (Anthropic direct)")
    sys.exit(0)

result = subprocess.run(
    [sys.executable, "-c", redaction_code],
    input=settings_json,
    env=os.environ,
    text=True,
    capture_output=True,
    check=False,
)
if result.returncode == 0:
    sys.stdout.write(result.stdout)
else:
    print("(could not parse settings)")
PY
}

# ── Test 1: claude-status redacts secret-like env vars ─────────
echo "Test 1: claude-status redacts secret-like env vars"

FAKE_HOME="$TMPDIR_ROOT/home1"
mkdir -p "$FAKE_HOME/.claude"
cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "sk-super-secret-token",
    "LITELLM_MASTER_KEY": "sk-another-secret",
    "MY_PASSWORD": "hunter2",
    "MY_CREDENTIAL": "cred-value",
    "ANTHROPIC_MODEL": "claude-sonnet-4-6"
  }
}
JSON

# Exercise the real Makefile target with a fake HOME. Stub curl so the proxy
# health check cannot make a network request while preserving target behavior.
STATUS_STUB_DIR="$TMPDIR_ROOT/status-stubs"
mkdir -p "$STATUS_STUB_DIR"
cat > "$STATUS_STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
chmod +x "$STATUS_STUB_DIR/curl"

if ! STATUS_OUTPUT=$(run_claude_status "$FAKE_HOME" 2>/dev/null); then
    fail "claude-status failed for valid settings"
fi

if echo "$STATUS_OUTPUT" | grep -q "sk-super-secret-token"; then
    fail "ANTHROPIC_AUTH_TOKEN was not redacted"
elif echo "$STATUS_OUTPUT" | grep -q "sk-another-secret"; then
    fail "LITELLM_MASTER_KEY was not redacted"
elif echo "$STATUS_OUTPUT" | grep -q "hunter2"; then
    fail "MY_PASSWORD was not redacted"
elif echo "$STATUS_OUTPUT" | grep -q "cred-value"; then
    fail "MY_CREDENTIAL was not redacted"
elif ! echo "$STATUS_OUTPUT" | grep -q "claude-sonnet-4-6"; then
    fail "ANTHROPIC_MODEL should remain visible but was removed"
else
    pass "All secret-like keys redacted; non-secret keys preserved"
fi

# Verify invalid JSON doesn't leak file contents
echo "Test 1b: invalid settings JSON does not print file contents"
FAKE_HOME2="$TMPDIR_ROOT/home1b"
mkdir -p "$FAKE_HOME2/.claude"
echo "NOT-JSON { secret: sk-leaked }" > "$FAKE_HOME2/.claude/settings.json"

if ! INVALID_OUTPUT=$(run_claude_status "$FAKE_HOME2" 2>/dev/null); then
    fail "claude-status failed for invalid settings"
    INVALID_OUTPUT=""
fi

if echo "$INVALID_OUTPUT" | grep -q "sk-leaked"; then
    fail "Invalid JSON leaked file contents"
else
    pass "Invalid JSON handled safely"
fi

# ── Test 2: claude_enable.py reads master key from env ─────────
echo "Test 2: claude_enable.py reads master key from env"

FAKE_HOME3="$TMPDIR_ROOT/home2"
FAKE_SETTINGS_FILE="$FAKE_HOME3/.claude/settings.json"
mkdir -p "$(dirname "$FAKE_SETTINGS_FILE")"

REAL_SETTINGS_FILE=$(python3 -c 'from pathlib import Path; print(Path.home() / ".claude" / "settings.json")')
if [ "$FAKE_SETTINGS_FILE" = "$REAL_SETTINGS_FILE" ]; then
    echo "Refusing to run: fake settings path resolved to real Claude settings" >&2
    exit 1
fi

# Should succeed when LITELLM_MASTER_KEY is in env
FAKE_KEY="sk-test-fake-key-12345"
CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE" LITELLM_MASTER_KEY="$FAKE_KEY" python3 scripts/claude_enable.py > /dev/null 2>&1

WRITTEN=$(CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE" python3 -c "
import json, os
from pathlib import Path
d = json.load(open(Path(os.environ['CLAUDE_SETTINGS_FILE'])))
print(d['env']['ANTHROPIC_AUTH_TOKEN'])
")

if [ "$WRITTEN" = "$FAKE_KEY" ]; then
    pass "Master key read from env and written to settings"
else
    fail "Master key mismatch: expected $FAKE_KEY, got $WRITTEN"
fi

# Should fail when LITELLM_MASTER_KEY is missing
if CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE" LITELLM_MASTER_KEY="" python3 scripts/claude_enable.py 2>/dev/null; then
    fail "claude_enable.py should fail when LITELLM_MASTER_KEY is empty"
else
    pass "claude_enable.py fails with clear error when key missing"
fi

# ── Test 3: Copilot token not in curl argv ─────────────────────
echo "Test 3: Copilot token not exposed in curl argv"

FAKE_TOKEN="ghp-fake-copilot-token-99999"
FAKE_HOME4="$TMPDIR_ROOT/home3"
FAKE_TOKEN_DIR="$FAKE_HOME4/.config/litellm/github_copilot"
mkdir -p "$FAKE_TOKEN_DIR"
echo -n "$FAKE_TOKEN" > "$FAKE_TOKEN_DIR/access-token"

# Create a stub curl that logs its argv and exits
STUB_DIR="$TMPDIR_ROOT/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Log all arguments to a file for inspection
echo "$@" >> "$CURL_LOG"
# Return empty JSON so jq doesn't error
echo '{"data":[]}'
STUB
chmod +x "$STUB_DIR/curl"

cat > "$STUB_DIR/jq" <<'STUB'
#!/usr/bin/env bash
# Consume stdin and exit successfully so the model-list script runs offline.
cat >/dev/null
STUB
chmod +x "$STUB_DIR/jq"

export CURL_LOG="$TMPDIR_ROOT/curl_args.log"
: > "$CURL_LOG"

# Run list-copilot-models.sh with stubbed curl and fake HOME
if ! HOME="$FAKE_HOME4" PATH="$STUB_DIR:$PATH" bash scripts/list-copilot-models.sh > /dev/null 2>&1; then
    fail "list-copilot-models.sh failed with stubbed dependencies"
fi

if [[ ! -s "$CURL_LOG" ]]; then
    fail "list-copilot-models.sh did not invoke curl"
fi

if grep -q "$FAKE_TOKEN" "$CURL_LOG"; then
    fail "Copilot token appeared in curl argv"
else
    pass "Copilot token not present in curl command-line arguments"
fi

# ── Summary ────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
