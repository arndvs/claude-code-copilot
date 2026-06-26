#!/usr/bin/env bash
# test_version_doc.sh — Verify /health/version is documented in §7 (Verify)
#
# Acceptance criteria (from issue #61):
#   1. docs/hosted_deployment.md §7 includes a curl command for /health/version
#   2. Expected JSON output shape is shown (sha, built_at)
#   3. A note explains this replaces the need to SSH/SSM and run git log
#
# Usage: bash tests/test_version_doc.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

DOC="docs/hosted_deployment.md"

if [ ! -f "$DOC" ]; then
    echo "ERROR: $DOC not found"
    exit 1
fi

# Extract §7 (Verify) section — from "## 7. Verify" to the next numbered "## N." heading
verify_section=$(sed -n '/^## 7\. Verify/,/^## [0-9][0-9]*\./p' "$DOC" | sed '$d')

if [ -z "$verify_section" ]; then
    echo "ERROR: Could not find §7 (Verify) section in $DOC"
    exit 1
fi

# ── Test 1: §7 includes a curl command for /health/version ────────────────
echo "Test 1: §7 includes a curl command for /health/version"
if echo "$verify_section" | grep -q 'curl.*\/health\/version'; then
    pass "§7 contains a curl command targeting /health/version"
else
    fail "§7 does not contain a curl command targeting /health/version"
fi

# ── Test 2: Expected JSON output shape shown (sha and built_at keys) ──────
echo "Test 2: Expected JSON output shows both 'sha' and 'built_at' keys"
if echo "$verify_section" | grep -q '"sha"' && \
   echo "$verify_section" | grep -q '"built_at"'; then
    pass "§7 shows expected JSON with 'sha' and 'built_at' keys"
else
    fail "§7 does not show expected JSON output with both 'sha' and 'built_at' keys"
fi

# ── Test 3: Note explains this replaces SSH/SSM git log ───────────────────
echo "Test 3: Note explains /health/version replaces SSH/SSM for version checking"
if echo "$verify_section" | grep -qi 'ssh\|ssm' && \
   echo "$verify_section" | grep -qi 'version\|deployed\|redeploy'; then
    pass "§7 contains a note about replacing SSH/SSM for version checking"
else
    fail "§7 does not explain that /health/version replaces SSH/SSM access for version checking"
fi

# ── Test 4: The curl example does not require auth (no Authorization header) ──
echo "Test 4: The /health/version curl example does not include Authorization header"
# Extract just the curl line(s) for /health/version
version_curl=$(echo "$verify_section" | grep -A2 'curl.*\/health\/version' || true)
if [ -n "$version_curl" ]; then
    if echo "$version_curl" | grep -qi 'Authorization'; then
        fail "/health/version curl example includes Authorization (should not require auth)"
    else
        pass "/health/version curl example does not require Authorization header"
    fi
else
    fail "Could not find /health/version curl command to check for auth"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
