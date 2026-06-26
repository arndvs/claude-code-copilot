#!/usr/bin/env bash
# test_qa_checklist.sh — Validate the QA verification script's precondition checks
#
# This runs the static/precondition portion of qa_health_version.sh to ensure
# the QA checklist script itself is correct and that all infrastructure pieces
# are in place (files exist, Dockerfile is configured, hooks are wired, etc.).
#
# These checks do NOT require a running proxy or Docker daemon — they only
# verify the codebase is properly assembled for the /health/version feature.
#
# Usage: bash tests/test_qa_checklist.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

echo "test_qa_checklist.sh — Validate QA script structure and preconditions"
echo ""

# ── Test 1: QA script exists and is executable ────────────────────────────
echo "Test 1: qa_health_version.sh exists"
if [ -f "tests/qa_health_version.sh" ]; then
    pass "tests/qa_health_version.sh exists"
else
    fail "tests/qa_health_version.sh not found"
fi

# ── Test 2: QA script has proper bash header ──────────────────────────────
echo "Test 2: QA script has proper bash shebang and strict mode"
if head -2 "tests/qa_health_version.sh" | grep -q '#!/usr/bin/env bash' && \
   grep -q 'set -euo pipefail' "tests/qa_health_version.sh"; then
    pass "Proper shebang and strict mode"
else
    fail "Missing proper shebang or strict mode"
fi

# ── Test 3: QA script covers all acceptance criteria from issue #62 ───────
echo "Test 3: QA script covers all acceptance criteria"
all_covered=true

# AC1: Local dev check
if ! grep -q 'make start\|local.*dev\|LOCAL DEV' "tests/qa_health_version.sh"; then
    echo "     Missing: local dev check"
    all_covered=false
fi

# AC2: Docker without args
if ! grep -q 'Docker build without' "tests/qa_health_version.sh"; then
    echo "     Missing: Docker without args check"
    all_covered=false
fi

# AC3: Docker with args
if ! grep -q 'Docker build with' "tests/qa_health_version.sh"; then
    echo "     Missing: Docker with args check"
    all_covered=false
fi

# AC4: No auth required
if ! grep -q '[Nn]o auth\|without.*[Aa]uthorization\|No auth required' "tests/qa_health_version.sh"; then
    echo "     Missing: no auth check"
    all_covered=false
fi

# AC5: /health/readiness unchanged
if ! grep -q '/health/readiness' "tests/qa_health_version.sh"; then
    echo "     Missing: /health/readiness check"
    all_covered=false
fi

# AC6: Proxy completion routes
if ! grep -q 'completion\|/v1/messages' "tests/qa_health_version.sh"; then
    echo "     Missing: completion routes check"
    all_covered=false
fi

if [ "$all_covered" = true ]; then
    pass "All 6 acceptance criteria from issue #62 are covered"
else
    fail "Not all acceptance criteria are covered"
fi

# ── Test 4: QA script supports --local, --docker, --all flags ─────────────
echo "Test 4: QA script supports mode flags"
if grep -q '\-\-local' "tests/qa_health_version.sh" && \
   grep -q '\-\-docker' "tests/qa_health_version.sh" && \
   grep -q '\-\-all' "tests/qa_health_version.sh"; then
    pass "Supports --local, --docker, and --all flags"
else
    fail "Missing one or more mode flags (--local, --docker, --all)"
fi

# ── Test 5: Precondition checks pass (static analysis of codebase) ────────
echo "Test 5: Precondition checks pass on current codebase"

# Re-implement the preconditions inline to verify independently
preconditions_ok=true

if [ ! -f "health_version.py" ]; then
    echo "     Missing: health_version.py"
    preconditions_ok=false
fi

if ! grep -q 'ARG BUILD_SHA' Dockerfile || ! grep -q 'ARG BUILD_TIMESTAMP' Dockerfile; then
    echo "     Missing: Dockerfile ARGs"
    preconditions_ok=false
fi

if ! grep -qE 'ENV[[:space:]]+BUILD_SHA=\$\{?BUILD_SHA\}?' Dockerfile || ! grep -qE 'ENV[[:space:]]+BUILD_TIMESTAMP=\$\{?BUILD_TIMESTAMP\}?' Dockerfile; then
    echo "     Missing: Dockerfile ENV forwarding"
    preconditions_ok=false
fi

if ! grep -q 'health_version.version_callback_instance' litellm_config.yaml; then
    echo "     Missing: litellm_config.yaml health_version callback"
    preconditions_ok=false
fi

if ! grep -q '/health/version' docs/hosted_deployment.md; then
    echo "     Missing: docs reference"
    preconditions_ok=false
fi

if ! grep -q 'COPY health_version.py' Dockerfile; then
    echo "     Missing: Dockerfile COPY health_version.py"
    preconditions_ok=false
fi

if [ "$preconditions_ok" = true ]; then
    pass "All codebase preconditions for /health/version are met"
else
    fail "One or more codebase preconditions not met"
fi

# ── Test 6: QA script references issue #62 and PRD #57 ───────────────────
echo "Test 6: QA script references the parent PRD and this issue"
if grep -q '#62\|issue.*62' "tests/qa_health_version.sh" && \
   grep -q '#57\|PRD.*57' "tests/qa_health_version.sh"; then
    pass "Script references issue #62 and PRD #57"
else
    fail "Script should reference issue #62 and PRD #57 for traceability"
fi

# ── Test 7: QA script outputs structured results ─────────────────────────
echo "Test 7: QA script outputs structured pass/fail results"
if grep -q 'PASS\|pass()' "tests/qa_health_version.sh" && \
   grep -q 'FAIL\|fail()' "tests/qa_health_version.sh" && \
   grep -q 'SUMMARY\|Results:' "tests/qa_health_version.sh"; then
    pass "Script outputs structured pass/fail/summary"
else
    fail "Script should output structured pass/fail results"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
