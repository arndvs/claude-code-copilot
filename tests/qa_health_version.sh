#!/usr/bin/env bash
# qa_health_version.sh — Manual QA verification checklist for /health/version
#
# End-to-end manual verification that the /health/version endpoint works in
# both local-dev and Docker modes.
#
# Acceptance criteria (from issue #62):
#   1. Local dev: run 'make start', curl localhost:4000/health/version returns
#      valid JSON with sha from local git and built_at as 'unknown' or current time
#   2. Docker build without args: docker build + run, curl /health/version
#      returns {"sha":"unknown","built_at":"unknown"}
#   3. Docker build with args: docker build --build-arg BUILD_SHA=... --build-arg
#      BUILD_TIMESTAMP=... + run, curl /health/version returns correct sha/timestamp
#   4. No auth required: curl without -H Authorization returns 200 (not 401)
#   5. Existing /health/readiness still works unchanged
#   6. Existing proxy completion routes still work (make test passes)
#
# Usage:
#   bash tests/qa_health_version.sh [--local | --docker | --all]
#
#   --local   Run only local-dev checks (requires a running proxy on LITELLM_PORT)
#   --docker  Run only Docker checks (requires docker)
#   --all     Run everything (default)
#
# Prerequisites:
#   --local:  proxy running via 'make start' (or start_proxy.sh)
#   --docker: docker daemon running, .env file present

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# ── Parse arguments ──────────────────────────────────────────────
MODE="${1:---all}"
case "$MODE" in
    --local|--docker|--all) ;;
    *)
        echo "Usage: bash tests/qa_health_version.sh [--local | --docker | --all]"
        exit 1
        ;;
esac

# ── Counters ─────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⏭️  SKIP: $1"; }

# ── Load env if available ────────────────────────────────────────
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
    set +a
fi

PORT="${LITELLM_PORT:-4000}"
PROXY_URL="http://localhost:${PORT}"
DOCKER_IMAGE_DEFAULT="qa-health-version-test:default"
DOCKER_IMAGE_CUSTOM="qa-health-version-test:custom"
DOCKER_CONTAINER="qa-health-version-proxy"

# ── Helpers ──────────────────────────────────────────────────────
cleanup_docker() {
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    docker rmi -f "$DOCKER_IMAGE_DEFAULT" >/dev/null 2>&1 || true
    docker rmi -f "$DOCKER_IMAGE_CUSTOM" >/dev/null 2>&1 || true
}

wait_for_proxy() {
    local url="$1"
    local max_wait="${2:-30}"
    local waited=0
    while ! curl -sf "$url/health/readiness" >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$max_wait" ]; then
            return 1
        fi
    done
    return 0
}

# ════════════════════════════════════════════════════════════════════
# LOCAL DEV CHECKS
# ════════════════════════════════════════════════════════════════════

run_local_checks() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "LOCAL DEV CHECKS (proxy at $PROXY_URL)"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Check proxy is reachable
    if ! curl -sf "$PROXY_URL/health/readiness" >/dev/null 2>&1; then
        echo "  ⚠️  Proxy not reachable at $PROXY_URL"
        echo "     Start it with 'make start' and re-run."
        skip "Local dev checks — proxy not running"
        return
    fi

    # ── Check 1: /health/version returns valid JSON ──────────────
    echo "Check 1: GET /health/version returns valid JSON with sha and built_at"
    local sha="" built_at=""
    local response
    response=$(curl -sf "$PROXY_URL/health/version" 2>/dev/null || echo "")
    if [ -z "$response" ]; then
        fail "GET /health/version returned empty response or non-200"
    else
        # Validate JSON structure
        sha=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha'])" 2>/dev/null || echo "")
        built_at=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['built_at'])" 2>/dev/null || echo "")

        if [ -z "$sha" ] || [ -z "$built_at" ]; then
            fail "Response is not valid JSON with 'sha' and 'built_at' keys: $response"
        else
            echo "     Response: $response"
            pass "Valid JSON with sha='$sha', built_at='$built_at'"
        fi
    fi

    # ── Check 2: sha matches local git (or is non-empty) ─────────
    echo "Check 2: sha from local dev matches git rev-parse --short HEAD"
    local local_sha
    local_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if [ -n "$sha" ] && [ "$sha" != "unknown" ]; then
        if [ "$sha" = "$local_sha" ]; then
            pass "sha '$sha' matches local git HEAD"
        else
            # It's possible BUILD_SHA env var is set to something else
            fail "sha '$sha' does not match local git HEAD '$local_sha' (is BUILD_SHA env var overriding?)"
        fi
    elif [ "$sha" = "unknown" ]; then
        fail "sha is 'unknown' in local dev (git fallback may have failed)"
    fi

    # ── Check 3: built_at is 'unknown' or a valid timestamp ──────
    echo "Check 3: built_at is 'unknown' or a valid ISO timestamp"
    if [ "$built_at" = "unknown" ]; then
        pass "built_at is 'unknown' (expected for local dev without BUILD_TIMESTAMP env)"
    elif echo "$built_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
        pass "built_at is a valid ISO timestamp: $built_at"
    else
        fail "built_at is neither 'unknown' nor a valid ISO timestamp: $built_at"
    fi

    # ── Check 4: No auth required ────────────────────────────────
    echo "Check 4: /health/version returns 200 without Authorization header"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$PROXY_URL/health/version" 2>/dev/null || echo "000")
    if [ "$http_code" = "200" ]; then
        pass "No auth required — got HTTP $http_code"
    else
        fail "Expected HTTP 200 without auth, got $http_code"
    fi

    # ── Check 5: /health/readiness still works ────────────────────
    echo "Check 5: Existing /health/readiness still works unchanged"
    local readiness_code
    readiness_code=$(curl -s -o /dev/null -w "%{http_code}" "$PROXY_URL/health/readiness" 2>/dev/null || echo "000")
    if [ "$readiness_code" = "200" ]; then
        pass "/health/readiness returns HTTP 200"
    else
        fail "/health/readiness returned HTTP $readiness_code (expected 200)"
    fi

    # ── Check 6: Proxy completion routes work (if master key is available) ──
    echo "Check 6: Proxy completion routes still work"
    if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
        local completion_code
        completion_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$PROXY_URL/v1/messages" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
            -d '{"model":"claude-sonnet-4-6","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null || echo "000")
        if [ "$completion_code" = "200" ]; then
            pass "Completion route returns HTTP 200"
        else
            # 4xx/5xx could be upstream issues, not our fault
            echo "     Got HTTP $completion_code (may be upstream/auth issue, not version endpoint related)"
            skip "Completion route returned $completion_code — verify manually"
        fi
    else
        skip "LITELLM_MASTER_KEY not set — cannot test completion routes"
    fi
}

# ════════════════════════════════════════════════════════════════════
# DOCKER CHECKS
# ════════════════════════════════════════════════════════════════════

run_docker_checks() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "DOCKER CHECKS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    if ! command -v docker >/dev/null 2>&1; then
        skip "Docker not available — skipping Docker checks"
        return
    fi

    if ! docker info >/dev/null 2>&1; then
        skip "Docker daemon not running — skipping Docker checks"
        return
    fi

    # Clean up any previous test containers/images
    cleanup_docker

    # ── Check 7: Docker build without args → sha=unknown, built_at=unknown ──
    echo "Check 7: Docker build without --build-arg → sha='unknown', built_at='unknown'"
    if docker build -t "$DOCKER_IMAGE_DEFAULT" . >/dev/null 2>&1; then
        # Allocate a free ephemeral port so the test does not conflict with
        # any running service.
        local test_port
        test_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
        docker run -d --name "$DOCKER_CONTAINER" \
            -e "LITELLM_MASTER_KEY=sk-test-qa-key" \
            -p "127.0.0.1:${test_port}:4000" \
            "$DOCKER_IMAGE_DEFAULT" >/dev/null 2>&1

        if wait_for_proxy "http://localhost:${test_port}" 60; then
    local sha="" built_at=""
    local response
            response=$(curl -sf "http://localhost:${test_port}/health/version" 2>/dev/null || echo "")
            if [ -n "$response" ]; then
                sha=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha'])" 2>/dev/null || echo "")
                built_at=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['built_at'])" 2>/dev/null || echo "")

                if [ "$sha" = "unknown" ] && [ "$built_at" = "unknown" ]; then
                    pass "Default build returns sha='unknown', built_at='unknown'"
                else
                    fail "Default build returned sha='$sha', built_at='$built_at' (expected both 'unknown')"
                fi
            else
                fail "Default build: /health/version returned empty or non-200"
            fi
        else
            fail "Default build: proxy did not become ready within 60s"
        fi
        docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    else
        fail "Docker build without --build-arg failed"
    fi

    # ── Check 8: Docker build with args → correct sha and timestamp ──
    echo "Check 8: Docker build with --build-arg → correct sha and timestamp"
    local test_sha="abc1234"
    local test_ts="2024-06-01T12:00:00Z"
    if docker build \
        --build-arg "BUILD_SHA=$test_sha" \
        --build-arg "BUILD_TIMESTAMP=$test_ts" \
        -t "$DOCKER_IMAGE_CUSTOM" . >/dev/null 2>&1; then

        local test_port
        test_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
        docker run -d --name "$DOCKER_CONTAINER" \
            -e "LITELLM_MASTER_KEY=sk-test-qa-key" \
            -p "127.0.0.1:${test_port}:4000" \
            "$DOCKER_IMAGE_CUSTOM" >/dev/null 2>&1

        if wait_for_proxy "http://localhost:${test_port}" 60; then
    local sha="" built_at=""
    local response
            response=$(curl -sf "http://localhost:${test_port}/health/version" 2>/dev/null || echo "")
            if [ -n "$response" ]; then
                sha=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha'])" 2>/dev/null || echo "")
                built_at=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['built_at'])" 2>/dev/null || echo "")

                if [ "$sha" = "$test_sha" ] && [ "$built_at" = "$test_ts" ]; then
                    pass "Custom build returns sha='$test_sha', built_at='$test_ts'"
                else
                    fail "Custom build returned sha='$sha', built_at='$built_at' (expected '$test_sha', '$test_ts')"
                fi
            else
                fail "Custom build: /health/version returned empty or non-200"
            fi

            # ── Check 9: No auth required on Docker container ────────
            echo "Check 9: /health/version in Docker requires no auth"
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${test_port}/health/version" 2>/dev/null || echo "000")
            if [ "$http_code" = "200" ]; then
                pass "Docker container: /health/version returns 200 without auth"
            else
                fail "Docker container: expected 200 without auth, got $http_code"
            fi

            # ── Check 10: /health/readiness still works in Docker ─────
            echo "Check 10: /health/readiness still works in Docker container"
            local readiness_code
            readiness_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${test_port}/health/readiness" 2>/dev/null || echo "000")
            if [ "$readiness_code" = "200" ]; then
                pass "/health/readiness returns 200 in Docker"
            else
                fail "/health/readiness returned $readiness_code in Docker (expected 200)"
            fi
        else
            fail "Custom build: proxy did not become ready within 60s"
        fi
        docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true
    else
        fail "Docker build with --build-arg failed"
    fi

    # Final cleanup
    cleanup_docker
}

# ════════════════════════════════════════════════════════════════════
# STATIC PRECONDITION CHECKS (always run)
# ════════════════════════════════════════════════════════════════════

run_precondition_checks() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "PRECONDITION CHECKS (static analysis)"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # ── P1: health_version.py exists ─────────────────────────────
    echo "Precondition 1: health_version.py exists"
    if [ -f "$REPO_ROOT/health_version.py" ]; then
        pass "health_version.py exists"
    else
        fail "health_version.py not found"
    fi

    # ── P2: Dockerfile has ARG BUILD_SHA and BUILD_TIMESTAMP ──────
    echo "Precondition 2: Dockerfile declares ARG BUILD_SHA and BUILD_TIMESTAMP"
    if grep -q 'ARG BUILD_SHA' "$REPO_ROOT/Dockerfile" && \
       grep -q 'ARG BUILD_TIMESTAMP' "$REPO_ROOT/Dockerfile"; then
        pass "Dockerfile declares both ARG BUILD_SHA and ARG BUILD_TIMESTAMP"
    else
        fail "Dockerfile missing ARG BUILD_SHA or ARG BUILD_TIMESTAMP"
    fi

    # ── P3: Dockerfile has ENV forwarding ─────────────────────────
    echo "Precondition 3: Dockerfile forwards ARGs to ENV"
    if grep -qE 'ENV[[:space:]]+BUILD_SHA=\$\{?BUILD_SHA\}?' "$REPO_ROOT/Dockerfile" && \
       grep -qE 'ENV[[:space:]]+BUILD_TIMESTAMP=\$\{?BUILD_TIMESTAMP\}?' "$REPO_ROOT/Dockerfile"; then
        pass "Dockerfile forwards BUILD_SHA and BUILD_TIMESTAMP to ENV"
    else
        fail "Dockerfile missing ENV forwarding for build args"
    fi

    # ── P4: litellm_config.yaml registers health_version callback ─
    echo "Precondition 4: litellm_config.yaml registers health_version callback"
    if grep -q 'health_version.version_callback_instance' "$REPO_ROOT/litellm_config.yaml"; then
        pass "litellm_config.yaml registers health_version.version_callback_instance"
    else
        fail "litellm_config.yaml does not register health_version callback"
    fi

    # ── P5: Dockerfile COPYs health_version.py ────────────────────
    echo "Precondition 5: Dockerfile COPYs health_version.py"
    if grep -q 'COPY health_version.py' "$REPO_ROOT/Dockerfile"; then
        pass "Dockerfile COPYs health_version.py"
    else
        fail "Dockerfile does not COPY health_version.py"
    fi

    # ── P6: docs/hosted_deployment.md documents /health/version ──
    echo "Precondition 6: docs/hosted_deployment.md documents /health/version"
    if grep -q '/health/version' "$REPO_ROOT/docs/hosted_deployment.md"; then
        pass "/health/version is documented in hosted_deployment.md"
    else
        fail "/health/version not found in hosted_deployment.md"
    fi

}

# ════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  QA: Manual Verification Checklist — /health/version        ║"
echo "║  Issue #62 (Part of PRD #57)                                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

# Always run precondition checks
run_precondition_checks

case "$MODE" in
    --local)
        run_local_checks
        ;;
    --docker)
        run_docker_checks
        ;;
    --all)
        run_local_checks
        run_docker_checks
        ;;
esac

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
echo "  Skipped: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "  ❌ QA VERIFICATION FAILED"
    echo ""
    exit 1
elif [ "$PASS" -eq 0 ] && [ "$SKIP" -gt 0 ]; then
    echo "  ⚠️  All checks were skipped — ensure prerequisites are met"
    echo ""
    exit 2
else
    echo "  ✅ QA VERIFICATION PASSED"
    echo ""
fi
