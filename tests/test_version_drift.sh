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

# ── Test 3: shared launch function reads from .litellm-version ─
echo "Test 3: shared launch function reads version from .litellm-version"
# The version is read once in scripts/_launch_proxy.sh (refs #127), which both
# Makefile:start and start_proxy.sh source — so a single file bump updates all
# execution paths.
if grep -Fq 'cat "$LAUNCH_PROXY_ROOT/.litellm-version"' scripts/_launch_proxy.sh; then
    pass "scripts/_launch_proxy.sh reads .litellm-version"
else
    fail "scripts/_launch_proxy.sh does not read .litellm-version"
fi

# ── Test 4: both entry points delegate to the shared launch fn ─
echo "Test 4: Makefile and start_proxy.sh delegate to the shared launch function"
if grep -Fq 'source scripts/_launch_proxy.sh' Makefile \
   && grep -Fq 'source "$SCRIPT_DIR/scripts/_launch_proxy.sh"' start_proxy.sh; then
    pass "Makefile and start_proxy.sh source the shared launch function"
else
    fail "Makefile and/or start_proxy.sh do not source the shared launch function"
fi

# ── Test 5: No hardcoded litellm[proxy]==<version> diverges ───
echo "Test 5: No hardcoded litellm[proxy]==<version> diverges from .litellm-version"
VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || echo "")
if [ -n "$VERSION" ]; then
    # Find any hardcoded litellm[proxy]==X.Y.Z pins that don't match the file.
    # Consumers that read .litellm-version use ${LITELLM_VERSION} or $(cat ...),
    # so a literal ==<semver> pin is a drift signal. Filter on the full
    # "litellm[proxy]==<version>" string with an exact line match (-x) so a
    # pinned version that is a prefix of another (e.g. 1.89.1 vs 1.89.10) is
    # still flagged as drift.
    drift=$(grep -RhoE 'litellm\[proxy\]==[0-9]+\.[0-9]+\.[0-9]+' \
        Dockerfile Makefile start_proxy.sh scripts/_launch_proxy.sh 2>/dev/null \
        | grep -Fxv "litellm[proxy]==${VERSION}" || true)
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
