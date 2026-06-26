#!/usr/bin/env bash
# test_build_args_in_docs.sh — Verify all docker build commands pass version build-args
#
# Acceptance criteria (from issue #60):
#   1. docs/hosted_deployment.md 'docker build' commands in the redeploy section
#      include --build-arg GIT_SHA=... --build-arg BUILD_TIMESTAMP=...
#   2. docs/hosted_deployment.md ECR build-and-push section includes the same
#   3. No existing docker build invocation in the doc is left without the new args
#
# Usage: bash tests/test_build_args_in_docs.sh

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

# ── Helper: extract docker build commands (may span multiple lines via \) ──
# Joins continuation lines (trailing \) then filters for 'docker build' (not 'docker builder')
joined_doc=$(sed ':a;/\\$/N;s/\\\n//;ta' "$DOC")
# Use word-boundary match: 'docker build ' or 'docker build\t' — excludes 'docker builder'

# ── Test 1: Every 'docker build' line includes --build-arg GIT_SHA ──────────
echo "Test 1: Every 'docker build' command includes --build-arg GIT_SHA"
build_lines=$(echo "$joined_doc" | grep -E 'docker build[[:space:]]+-' | grep -cv 'docker builder' || true)
sha_lines=$(echo "$joined_doc" | grep -E 'docker build[[:space:]]+-' | grep -v 'docker builder' | grep -c '\-\-build-arg.*GIT_SHA' || true)

if [ "$build_lines" -eq 0 ]; then
    fail "No 'docker build' commands found in $DOC"
elif [ "$build_lines" -eq "$sha_lines" ]; then
    pass "All $build_lines docker build commands include --build-arg GIT_SHA ($sha_lines/$build_lines)"
else
    fail "Only $sha_lines of $build_lines docker build commands include --build-arg GIT_SHA"
fi

# ── Test 2: Every 'docker build' line includes --build-arg BUILD_TIMESTAMP ──
echo "Test 2: Every 'docker build' command includes --build-arg BUILD_TIMESTAMP"
ts_lines=$(echo "$joined_doc" | grep -E 'docker build[[:space:]]+-' | grep -v 'docker builder' | grep -c '\-\-build-arg.*BUILD_TIMESTAMP' || true)

if [ "$build_lines" -eq 0 ]; then
    fail "No 'docker build' commands found in $DOC"
elif [ "$build_lines" -eq "$ts_lines" ]; then
    pass "All $build_lines docker build commands include --build-arg BUILD_TIMESTAMP ($ts_lines/$build_lines)"
else
    fail "Only $ts_lines of $build_lines docker build commands include --build-arg BUILD_TIMESTAMP"
fi

# ── Test 3: GIT_SHA uses git rev-parse --short HEAD ────────────────────────
echo "Test 3: GIT_SHA build-arg uses git rev-parse --short HEAD"
sha_correct=$(echo "$joined_doc" | grep -E 'docker build[[:space:]]+-' | grep -v 'docker builder' | grep -c 'GIT_SHA=\$(git rev-parse --short HEAD)' || true)

if [ "$build_lines" -eq "$sha_correct" ]; then
    pass "All docker build commands use GIT_SHA=\$(git rev-parse --short HEAD)"
else
    fail "Only $sha_correct of $build_lines docker build commands use correct GIT_SHA formula"
fi

# ── Test 4: BUILD_TIMESTAMP uses date -u ISO format ───────────────────────
echo "Test 4: BUILD_TIMESTAMP build-arg uses date -u ISO format"
ts_correct=$(echo "$joined_doc" | grep -E 'docker build[[:space:]]+-' | grep -v 'docker builder' | grep -c 'BUILD_TIMESTAMP=\$(date -u' || true)

if [ "$build_lines" -eq "$ts_correct" ]; then
    pass "All docker build commands use BUILD_TIMESTAMP=\$(date -u ...)"
else
    fail "Only $ts_correct of $build_lines docker build commands use correct BUILD_TIMESTAMP formula"
fi

# ── Test 5: Redeploy section (§8 build-on-box) has the args ────────────────
echo "Test 5: Redeploy section (build-on-box) docker build has both args"
# Extract lines between "Redeploy after a repo update" and the next ### heading
redeploy_section=$(sed -n '/### Redeploy after a repo update/,/^### /p' "$DOC" | sed '$d')
redeploy_build=$(echo "$redeploy_section" | sed ':a;/\\$/N;s/\\\n//;ta' | grep 'docker build' || true)

if [ -z "$redeploy_build" ]; then
    fail "No docker build found in redeploy section"
elif echo "$redeploy_build" | grep -q '\-\-build-arg.*GIT_SHA' && \
     echo "$redeploy_build" | grep -q '\-\-build-arg.*BUILD_TIMESTAMP'; then
    pass "Redeploy section docker build includes both build-args"
else
    fail "Redeploy section docker build missing one or both build-args"
fi

# ── Test 6: ECR build-and-push section has the args ────────────────────────
echo "Test 6: ECR build-and-push section docker build has both args"
# Extract lines between "Build and push" and "Deploy on the box"
ecr_section=$(sed -n '/\*\*2\. Build and push/,/\*\*3\. Deploy on the box/p' "$DOC" | sed '$d')
ecr_build=$(echo "$ecr_section" | sed ':a;/\\$/N;s/\\\n//;ta' | grep 'docker build' || true)

if [ -z "$ecr_build" ]; then
    fail "No docker build found in ECR build-and-push section"
elif echo "$ecr_build" | grep -q '\-\-build-arg.*GIT_SHA' && \
     echo "$ecr_build" | grep -q '\-\-build-arg.*BUILD_TIMESTAMP'; then
    pass "ECR build-and-push section docker build includes both build-args"
else
    fail "ECR build-and-push section docker build missing one or both build-args"
fi

# ── Summary ───────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
