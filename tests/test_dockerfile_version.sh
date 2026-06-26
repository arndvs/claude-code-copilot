#!/usr/bin/env bash
# test_dockerfile_version.sh — Verify Dockerfile bakes version metadata via ARG/ENV
#
# Acceptance criteria (from issue #58):
#   1. Dockerfile accepts --build-arg GIT_SHA and --build-arg BUILD_TIMESTAMP
#   2. docker build without --build-arg still succeeds (defaults to 'unknown')
#   3. docker build --build-arg GIT_SHA=abc1234 --build-arg BUILD_TIMESTAMP=2024-01-01T00:00:00Z
#      results in those values visible via env inside the container
#
# Usage: bash tests/test_dockerfile_version.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── Test 1: Dockerfile declares ARG GIT_SHA with default ──────────
echo "Test 1: Dockerfile declares ARG GIT_SHA with sensible default"
if grep -qE '^[[:space:]]*ARG[[:space:]]+GIT_SHA=' Dockerfile; then
    DEFAULT_SHA=$(grep -E '^[[:space:]]*ARG[[:space:]]+GIT_SHA=' Dockerfile | head -1 | sed 's/.*GIT_SHA=//')
    if [ "$DEFAULT_SHA" = "unknown" ]; then
        pass "ARG GIT_SHA=unknown declared"
    else
        fail "ARG GIT_SHA default is '$DEFAULT_SHA', expected 'unknown'"
    fi
else
    fail "Dockerfile does not declare ARG GIT_SHA with a default"
fi

# ── Test 2: Dockerfile declares ARG BUILD_TIMESTAMP with default ──
echo "Test 2: Dockerfile declares ARG BUILD_TIMESTAMP with sensible default"
if grep -qE '^[[:space:]]*ARG[[:space:]]+BUILD_TIMESTAMP=' Dockerfile; then
    DEFAULT_TS=$(grep -E '^[[:space:]]*ARG[[:space:]]+BUILD_TIMESTAMP=' Dockerfile | head -1 | sed 's/.*BUILD_TIMESTAMP=//')
    if [ "$DEFAULT_TS" = "unknown" ]; then
        pass "ARG BUILD_TIMESTAMP=unknown declared"
    else
        fail "ARG BUILD_TIMESTAMP default is '$DEFAULT_TS', expected 'unknown'"
    fi
else
    fail "Dockerfile does not declare ARG BUILD_TIMESTAMP with a default"
fi

# ── Test 3: Dockerfile forwards GIT_SHA to ENV ────────────────────
echo "Test 3: Dockerfile forwards GIT_SHA ARG to ENV"
if grep -qE '^[[:space:]]*ENV[[:space:]]+GIT_SHA=' Dockerfile; then
    # Verify it references the ARG (ENV GIT_SHA=$GIT_SHA or ENV GIT_SHA=${GIT_SHA})
    if grep -qE '^[[:space:]]*ENV[[:space:]]+GIT_SHA=\$\{?GIT_SHA\}?' Dockerfile; then
        pass "ENV GIT_SHA=\$GIT_SHA declared"
    else
        fail "ENV GIT_SHA is set but does not reference the ARG variable"
    fi
else
    fail "Dockerfile does not declare ENV GIT_SHA"
fi

# ── Test 4: Dockerfile forwards BUILD_TIMESTAMP to ENV ────────────
echo "Test 4: Dockerfile forwards BUILD_TIMESTAMP ARG to ENV"
if grep -qE '^[[:space:]]*ENV[[:space:]]+BUILD_TIMESTAMP=' Dockerfile; then
    if grep -qE '^[[:space:]]*ENV[[:space:]]+BUILD_TIMESTAMP=\$\{?BUILD_TIMESTAMP\}?' Dockerfile; then
        pass "ENV BUILD_TIMESTAMP=\$BUILD_TIMESTAMP declared"
    else
        fail "ENV BUILD_TIMESTAMP is set but does not reference the ARG variable"
    fi
else
    fail "Dockerfile does not declare ENV BUILD_TIMESTAMP"
fi

# ── Test 5: Docker build without --build-arg succeeds ─────────────
echo "Test 5: Docker build without --build-arg succeeds (uses defaults)"
if command -v docker >/dev/null 2>&1; then
    if docker build -t copilot-proxy-version-test:defaults . >/dev/null 2>&1; then
        # Verify defaults are 'unknown' inside the image
        SHA_VAL=$(docker run --rm copilot-proxy-version-test:defaults printenv GIT_SHA 2>/dev/null || echo "")
        TS_VAL=$(docker run --rm copilot-proxy-version-test:defaults printenv BUILD_TIMESTAMP 2>/dev/null || echo "")
        if [ "$SHA_VAL" = "unknown" ] && [ "$TS_VAL" = "unknown" ]; then
            pass "Build without --build-arg succeeds; defaults are 'unknown'"
        else
            fail "Defaults inside container: GIT_SHA='$SHA_VAL', BUILD_TIMESTAMP='$TS_VAL' (expected 'unknown')"
        fi
        docker rmi copilot-proxy-version-test:defaults >/dev/null 2>&1 || true
    else
        fail "Docker build without --build-arg failed"
    fi
else
    echo "  ⚠️  Docker not available — skipping runtime test (static checks passed)"
fi

# ── Test 6: Docker build with --build-arg exposes values in env ───
echo "Test 6: Docker build with explicit --build-arg values"
if command -v docker >/dev/null 2>&1; then
    TEST_SHA="abc1234"
    TEST_TS="2024-01-01T00:00:00Z"
    if docker build \
        --build-arg "GIT_SHA=$TEST_SHA" \
        --build-arg "BUILD_TIMESTAMP=$TEST_TS" \
        -t copilot-proxy-version-test:custom . >/dev/null 2>&1; then
        SHA_VAL=$(docker run --rm copilot-proxy-version-test:custom printenv GIT_SHA 2>/dev/null || echo "")
        TS_VAL=$(docker run --rm copilot-proxy-version-test:custom printenv BUILD_TIMESTAMP 2>/dev/null || echo "")
        if [ "$SHA_VAL" = "$TEST_SHA" ] && [ "$TS_VAL" = "$TEST_TS" ]; then
            pass "Build with --build-arg GIT_SHA=$TEST_SHA BUILD_TIMESTAMP=$TEST_TS visible in container"
        else
            fail "Values inside container: GIT_SHA='$SHA_VAL', BUILD_TIMESTAMP='$TS_VAL' (expected '$TEST_SHA', '$TEST_TS')"
        fi
        docker rmi copilot-proxy-version-test:custom >/dev/null 2>&1 || true
    else
        fail "Docker build with --build-arg failed"
    fi
else
    echo "  ⚠️  Docker not available — skipping runtime test (static checks passed)"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
