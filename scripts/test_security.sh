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

    # Some Windows Git Bash installs do not include make.
    if [ -f "$fake_home/.claude/settings.json" ]; then
        HOME="$fake_home" PATH="$STATUS_STUB_DIR:$PATH" python3 scripts/claude_status_redact.py < "$fake_home/.claude/settings.json" 2>/dev/null || echo '(could not parse settings)'
    else
        echo "No settings file — using Claude Code defaults (Anthropic direct)"
    fi
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
    "GITHUB_AUTH": "gh-auth-secret",
    "AUTH_HEADER": "bearer-secret",
    "MY_PASSWORD": "hunter2",
    "MY_CREDENTIAL": "cred-value",
    "ANTHROPIC_MODEL": "claude-sonnet-4-6",
    "AUTHOR": "Ada Lovelace",
    "AUTHORITY_URL": "https://login.example.test"
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
elif echo "$STATUS_OUTPUT" | grep -q "gh-auth-secret"; then
    fail "GITHUB_AUTH was not redacted"
elif echo "$STATUS_OUTPUT" | grep -q "hunter2"; then
    fail "MY_PASSWORD was not redacted"
elif echo "$STATUS_OUTPUT" | grep -q "cred-value"; then
    fail "MY_CREDENTIAL was not redacted"
elif echo "$STATUS_OUTPUT" | grep -q "bearer-secret"; then
    fail "AUTH_HEADER was not redacted"
elif ! echo "$STATUS_OUTPUT" | grep -q "claude-sonnet-4-6"; then
    fail "ANTHROPIC_MODEL should remain visible but was removed"
elif ! echo "$STATUS_OUTPUT" | grep -q "Ada Lovelace"; then
    fail "AUTHOR should remain visible but was removed"
elif ! echo "$STATUS_OUTPUT" | grep -q "https://login.example.test"; then
    fail "AUTHORITY_URL should remain visible but was removed"
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
elif echo "$INVALID_OUTPUT" | grep -q "Routing:"; then
    fail "Invalid JSON continued into routing detection"
elif echo "$INVALID_OUTPUT" | grep -q "Proxy:"; then
    fail "Invalid JSON continued into proxy health detection"
else
    pass "Invalid JSON handled safely"
fi

# Verify hosted proxy status is labeled and remediated correctly
echo "Test 1c: claude-status handles hosted proxy URLs"
if command -v make >/dev/null 2>&1; then
    FAKE_HOME_HOSTED="$TMPDIR_ROOT/home1c"
    mkdir -p "$FAKE_HOME_HOSTED/.claude"
    cat > "$FAKE_HOME_HOSTED/.claude/settings.json" <<'JSON'
  {
    "env": {
      "ANTHROPIC_BASE_URL": "https://proxy.example.test",
      "ANTHROPIC_AUTH_TOKEN": "sk-hosted-secret"
    }
  }
JSON

    if ! HOSTED_STATUS_OUTPUT=$(run_claude_status "$FAKE_HOME_HOSTED" 2>/dev/null); then
        fail "claude-status failed for hosted proxy settings"
    fi

    if echo "$HOSTED_STATUS_OUTPUT" | grep -q "sk-hosted-secret"; then
        fail "Hosted proxy status leaked auth token"
    elif ! echo "$HOSTED_STATUS_OUTPUT" | grep -q "Routing: hosted proxy"; then
        fail "Hosted proxy status was not labeled as hosted"
    elif echo "$HOSTED_STATUS_OUTPUT" | grep -q "run 'make start'"; then
        fail "Hosted proxy status suggested starting a local proxy"
    elif ! echo "$HOSTED_STATUS_OUTPUT" | grep -q "check the hosted proxy endpoint"; then
        fail "Hosted proxy status did not suggest checking the hosted endpoint"
    else
        pass "Hosted proxy status uses hosted label and remediation"
    fi
else
    pass "Hosted proxy status test skipped because make is unavailable"
fi

# Verify claude-enable does not use shell-dependent ~ paths for backups
echo "Test 1d: claude-enable uses HOME for backup paths"
if grep -A12 '^claude-enable:' Makefile | grep -q '~/.claude/settings.json'; then
    fail "claude-enable still uses shell-dependent ~/.claude/settings.json"
elif ! grep -A12 '^claude-enable:' Makefile | grep -q 'chmod 600 "\$\$BACKUP"'; then
    fail "claude-enable backup chmod does not quote BACKUP"
else
    pass "claude-enable backup path uses HOME-derived settings file"
fi

echo "Test 1d2: claude-disable uses HOME for backup paths"
if grep -A10 '^claude-disable:' Makefile | grep -q '~/.claude/settings.json'; then
    fail "claude-disable still uses shell-dependent ~/.claude/settings.json"
elif ! grep -A10 '^claude-disable:' Makefile | grep -q 'chmod 600 "\$\$BACKUP"'; then
    fail "claude-disable backup chmod does not quote BACKUP"
else
    pass "claude-disable backup path uses HOME-derived settings file"
fi

echo "Test 1e: claude-status treats IPv6 loopback as local"
if command -v make >/dev/null 2>&1; then
    FAKE_HOME_IPV6="$TMPDIR_ROOT/home1e"
    mkdir -p "$FAKE_HOME_IPV6/.claude"
    cat > "$FAKE_HOME_IPV6/.claude/settings.json" <<'JSON'
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://[::1]:4000",
    "ANTHROPIC_AUTH_TOKEN": "sk-ipv6-secret"
  }
}
JSON

    if IPV6_STATUS_OUTPUT=$(run_claude_status "$FAKE_HOME_IPV6" 2>/dev/null) && echo "$IPV6_STATUS_OUTPUT" | grep -q "Routing: local proxy"; then
        pass "claude-status local-host detection includes IPv6 loopback"
    else
        fail "claude-status local-host detection does not include IPv6 loopback"
    fi
elif grep -A20 'urlparse(sys.argv\[1\]).hostname' Makefile | grep -q '"::1"'; then
    pass "claude-status local-host detection includes IPv6 loopback"
else
    fail "claude-status local-host detection does not include IPv6 loopback"
fi

echo "Test 1f: claude-status validates proxy URL before curl"
if command -v make >/dev/null 2>&1; then
    FAKE_HOME_INVALID_URL="$TMPDIR_ROOT/home1f"
    mkdir -p "$FAKE_HOME_INVALID_URL/.claude"
    cat > "$FAKE_HOME_INVALID_URL/.claude/settings.json" <<'JSON'
{
  "env": {
    "ANTHROPIC_BASE_URL": "proxy.example.test",
    "ANTHROPIC_AUTH_TOKEN": "sk-invalid-secret"
  }
}
JSON

    if INVALID_URL_STATUS_OUTPUT=$(run_claude_status "$FAKE_HOME_INVALID_URL" 2>/dev/null) && echo "$INVALID_URL_STATUS_OUTPUT" | grep -q "Proxy URL in settings is invalid"; then
        pass "claude-status validates proxy URL before curl"
    else
        fail "claude-status does not validate proxy URL before curl"
    fi
elif grep -A12 'PROXY_URL="http://localhost' Makefile | grep -q 'Proxy URL in settings is invalid'; then
    pass "claude-status validates proxy URL before curl"
else
    fail "claude-status does not validate proxy URL before curl"
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

# Should preserve a configured hosted proxy endpoint when enabling Claude Code
echo "Test 2b: claude_enable.py preserves hosted proxy endpoint"
FAKE_HOME3B="$TMPDIR_ROOT/home2b"
FAKE_REPO="$TMPDIR_ROOT/repo2b"
FAKE_SETTINGS_FILE_2B="$FAKE_HOME3B/.claude/settings.json"
HOSTED_PROXY_URL="https://proxy.example.test"
mkdir -p "$(dirname "$FAKE_SETTINGS_FILE_2B")" "$FAKE_REPO/scripts"
cp scripts/claude_enable.py "$FAKE_REPO/scripts/claude_enable.py"
cat > "$FAKE_REPO/.env" <<EOF
LITELLM_MASTER_KEY=$FAKE_KEY
LITELLM_PORT=4999
PROXY_BASE_URL=$HOSTED_PROXY_URL
EOF

(
    cd "$FAKE_REPO"
    set -a
    . ./.env
    set +a
    ANTHROPIC_BASE_URL="https://shell.example.test" CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE_2B" python3 scripts/claude_enable.py > /dev/null 2>&1
)
WRITTEN_BASE_URL=$(CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE_2B" python3 -c "
import json, os
from pathlib import Path
d = json.load(open(Path(os.environ['CLAUDE_SETTINGS_FILE'])))
print(d['env']['ANTHROPIC_BASE_URL'])
")

if [ "$WRITTEN_BASE_URL" = "$HOSTED_PROXY_URL" ]; then
    pass "Hosted proxy endpoint preserved by claude-enable"
else
    fail "Hosted proxy endpoint precedence is wrong: expected $HOSTED_PROXY_URL, got $WRITTEN_BASE_URL"
fi

# Should ignore ambient ANTHROPIC_BASE_URL when PROXY_BASE_URL is not configured
echo "Test 2b2: claude_enable.py ignores ambient ANTHROPIC_BASE_URL"
FAKE_SETTINGS_FILE_2B2="$TMPDIR_ROOT/home2b2/.claude/settings.json"
mkdir -p "$(dirname "$FAKE_SETTINGS_FILE_2B2")"
ANTHROPIC_BASE_URL="https://shell.example.test" CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE_2B2" LITELLM_MASTER_KEY="$FAKE_KEY" LITELLM_PORT=4999 python3 scripts/claude_enable.py > /dev/null 2>&1
WRITTEN_DEFAULT_BASE_URL=$(CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE_2B2" python3 -c "
import json, os
from pathlib import Path
d = json.load(open(Path(os.environ['CLAUDE_SETTINGS_FILE'])))
print(d['env']['ANTHROPIC_BASE_URL'])
")

if [ "$WRITTEN_DEFAULT_BASE_URL" = "http://localhost:4999" ]; then
    pass "Ambient ANTHROPIC_BASE_URL ignored without PROXY_BASE_URL"
else
    fail "Ambient ANTHROPIC_BASE_URL changed default endpoint: got $WRITTEN_DEFAULT_BASE_URL"
fi

# Should reject invalid proxy endpoint values before writing Claude settings
echo "Test 2c: claude_enable.py rejects invalid proxy endpoint"
FAKE_SETTINGS_FILE_2C="$TMPDIR_ROOT/home2c/.claude/settings.json"
mkdir -p "$(dirname "$FAKE_SETTINGS_FILE_2C")"
if CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE_2C" LITELLM_MASTER_KEY="$FAKE_KEY" PROXY_BASE_URL="proxy.example.test" python3 scripts/claude_enable.py > /dev/null 2>&1; then
    fail "claude_enable.py should fail for proxy URL without a scheme"
elif [ -f "$FAKE_SETTINGS_FILE_2C" ]; then
    fail "claude_enable.py wrote settings after invalid proxy URL"
else
    pass "Invalid proxy endpoint rejected before settings write"
fi

echo "Test 2d: claude_enable.py expands CLAUDE_SETTINGS_FILE env vars"
FAKE_HOME_EXPAND="$TMPDIR_ROOT/home2d"
FAKE_SETTINGS_FILE_2D="$FAKE_HOME_EXPAND/.claude/settings.json"
mkdir -p "$FAKE_HOME_EXPAND"
HOME="$FAKE_HOME_EXPAND" CLAUDE_SETTINGS_FILE='$HOME/.claude/settings.json' LITELLM_MASTER_KEY="$FAKE_KEY" python3 scripts/claude_enable.py > /dev/null 2>&1
if [ -f "$FAKE_SETTINGS_FILE_2D" ]; then
    pass "CLAUDE_SETTINGS_FILE expands environment variables"
else
    fail "CLAUDE_SETTINGS_FILE environment variables were not expanded"
fi

echo "Test 2e: claude_enable.py repairs malformed env blocks"
FAKE_SETTINGS_FILE_2E="$TMPDIR_ROOT/home2e/.claude/settings.json"
mkdir -p "$(dirname "$FAKE_SETTINGS_FILE_2E")"
printf '{"env":[]}\n' > "$FAKE_SETTINGS_FILE_2E"
CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE_2E" LITELLM_MASTER_KEY="$FAKE_KEY" python3 scripts/claude_enable.py > /dev/null 2>&1
if CLAUDE_SETTINGS_FILE="$FAKE_SETTINGS_FILE_2E" EXPECTED_KEY="$FAKE_KEY" python3 -c "
import json, os, sys
from pathlib import Path
d = json.load(open(Path(os.environ['CLAUDE_SETTINGS_FILE'])))
env = d.get('env')
sys.exit(0 if isinstance(env, dict) and env.get('ANTHROPIC_AUTH_TOKEN') == os.environ['EXPECTED_KEY'] else 1)
"; then
    pass "Malformed env block repaired by claude-enable"
else
    fail "Malformed env block was not repaired"
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

# ── Test 3b: Empty Copilot token fails before curl ─────────────
echo "Test 3b: Empty Copilot token fails before curl"

FAKE_HOME5="$TMPDIR_ROOT/home4"
FAKE_EMPTY_TOKEN_DIR="$FAKE_HOME5/.config/litellm/github_copilot"
mkdir -p "$FAKE_EMPTY_TOKEN_DIR"
printf ' \n\r\t ' > "$FAKE_EMPTY_TOKEN_DIR/access-token"

export CURL_LOG="$TMPDIR_ROOT/curl_empty_token_args.log"
: > "$CURL_LOG"

if HOME="$FAKE_HOME5" PATH="$STUB_DIR:$PATH" bash scripts/list-copilot-models.sh > /dev/null 2>&1; then
    fail "list-copilot-models.sh should fail when the Copilot token file is empty"
elif [[ -s "$CURL_LOG" ]]; then
    fail "list-copilot-models.sh invoked curl with an empty Copilot token"
else
    pass "Empty Copilot token file fails before curl is invoked"
fi

# ── Summary ────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
