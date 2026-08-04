#!/usr/bin/env bash
# test_version_drift.sh — Verify all LiteLLM version consumers reference .litellm-version
#
# Acceptance criteria (from issue #126):
#   1. .litellm-version exists and contains a non-empty version string
#   2. Dockerfile reads the version from .litellm-version (not a hardcoded pin)
#   3. Makefile:start reads the version from .litellm-version
#   4. start_proxy.sh reads the version from .litellm-version
#   5. No consumer hardcodes a litellm[proxy]==<version> that diverges from .litellm-version
#
# Usage: bash tests/test_version_drift.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

VERSION_FILE=".litellm-version"

# ── Test 1: .litellm-version exists and is non-empty ──────────
echo "Test 1: .litellm-version exists and is non-empty"
if [ ! -f "$VERSION_FILE" ]; then
    fail ".litellm-version not found"
else
    VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
    if [ -z "$VERSION" ]; then
        fail ".litellm-version is empty"
    else
        pass ".litellm-version contains '$VERSION'"
    fi
fi

# ── Test 2: Dockerfile reads from .litellm-version ────────────
echo "Test 2: Dockerfile reads version from .litellm-version"
if grep -Fq 'COPY .litellm-version' Dockerfile && grep -Fq 'cat .litellm-version' Dockerfile; then
    pass "Dockerfile reads .litellm-version"
else
    fail "Dockerfile does not read .litellm-version (expected COPY + cat)"
fi

# ── Test 3: Makefile reads from .litellm-version ──────────────
echo "Test 3: Makefile reads version from .litellm-version"
if grep -Fq 'cat .litellm-version' Makefile; then
    pass "Makefile reads .litellm-version"
else
    fail "Makefile does not read .litellm-version"
fi

# ── Test 4: start_proxy.sh reads from .litellm-version ────────
echo "Test 4: start_proxy.sh reads version from .litellm-version"
if grep -Fq 'cat "$SCRIPT_DIR/.litellm-version"' start_proxy.sh; then
    pass "start_proxy.sh reads .litellm-version"
else
    fail "start_proxy.sh does not read .litellm-version"
fi

# ── Test 5: No hardcoded litellm[proxy]==<version> diverges ───
echo "Test 5: No hardcoded litellm[proxy]==<version> diverges from .litellm-version"
VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || echo "")
if [ -n "$VERSION" ]; then
    # Find any hardcoded litellm[proxy]==X.Y.Z pins that don't match the file.
    # Consumers that read .litellm-version use ${LITELLM_VERSION} or $(cat ...),
    # so a literal ==<semver> pin is a drift signal.
    drift=$(grep -RhoE 'litellm\[proxy\]==[0-9]+\.[0-9]+\.[0-9]+' \
        Dockerfile Makefile start_proxy.sh 2>/dev/null \
        | grep -Fv "==${VERSION}" || true)
    if [ -n "$drift" ]; then
        fail "Hardcoded litellm version(s) diverge from .litellm-version: $drift"
    else
        pass "No hardcoded litellm version diverges from .litellm-version"
    fi
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
