#!/usr/bin/env bash
# test_upsert_issue_inputs.sh — Validate the upsert-issue composite action
#
# Acceptance criteria (from issue #132):
#   1. .github/actions/upsert-issue/action.yml exists and parses as YAML
#   2. All required inputs are declared (label, label-color, label-description,
#      title, body, token)
#   3. The action declares the issue-number and action-taken outputs
#   4. The "open or update issue by label" shell block appears exactly once in
#      the repo (proxy-canary.yml and model-health.yml must use the action, not
#      inline shell)
#
# Usage: bash tests/test_upsert_issue_inputs.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

ACTION=".github/actions/upsert-issue/action.yml"

# ── Test 1: action.yml exists and parses ──────────────────────
echo "Test 1: action.yml exists and parses as YAML"
if [ ! -f "$ACTION" ]; then
    fail "$ACTION not found"
else
    if python3 -c "
import sys, yaml
data = yaml.safe_load(open('$ACTION', encoding='utf-8'))
assert isinstance(data, dict), 'action.yml did not parse as a mapping'
assert data.get('name'), 'action.yml missing name'
assert data.get('runs', {}).get('using') == 'composite', 'action must use composite'
print('OK')
" >/dev/null 2>&1; then
        pass "$ACTION parses and is a composite action"
    else
        fail "$ACTION did not parse or is not composite"
    fi
fi

# ── Test 2: all required inputs declared ──────────────────────
echo "Test 2: all required inputs declared"
REQUIRED_INPUTS="label label-color label-description title body token"
if python3 -c "
import sys, yaml
data = yaml.safe_load(open('$ACTION', encoding='utf-8'))
inputs = data.get('inputs', {})
required = set('$REQUIRED_INPUTS'.split())
missing = required - set(inputs.keys())
assert not missing, f'missing required inputs: {sorted(missing)}'
for name in required:
    assert inputs[name].get('required') is True, f'input {name!r} must be required'
print('OK')
" >/dev/null 2>&1; then
    pass "all required inputs declared and marked required"
else
    fail "one or more required inputs missing or not marked required"
fi

# ── Test 3: outputs declared ──────────────────────────────────
echo "Test 3: outputs declared"
if python3 -c "
import sys, yaml
data = yaml.safe_load(open('$ACTION', encoding='utf-8'))
outputs = data.get('outputs', {})
for name in ('issue-number', 'action-taken'):
    assert name in outputs, f'missing output {name!r}'
print('OK')
" >/dev/null 2>&1; then
    pass "issue-number and action-taken outputs declared"
else
    fail "issue-number and/or action-taken output missing"
fi

# ── Test 4: shell block appears exactly once ──────────────────
echo "Test 4: 'open or update issue by label' shell block appears exactly once"
# The canonical block lives in the composite action. Count occurrences of the
# distinctive gh issue list --label pattern across the repo (excluding the
# action itself, which is the single source). `|| true` guards the grep -v
# exit-1 (no lines pass) under `set -euo pipefail`.
COUNT=$(grep -rn --include='*.yml' --include='*.yaml' \
  'gh issue list --repo' .github/ 2>/dev/null | grep -v "$ACTION" || true | wc -l | tr -d ' ')
if [ "$COUNT" -eq 0 ]; then
    pass "no inline 'gh issue list' blocks remain outside the action"
else
    fail "found $COUNT inline 'gh issue list' block(s) outside the action — refactor to use ./.github/actions/upsert-issue"
fi

# ── Test 5: workflows reference the action ─────────────────────
echo "Test 5: proxy-canary.yml and model-health.yml use the action"
for wf in proxy-canary model-health; do
    if grep -q 'uses: ./.github/actions/upsert-issue' ".github/workflows/$wf.yml"; then
        pass "$wf.yml uses the upsert-issue action"
    else
        fail "$wf.yml does not use the upsert-issue action"
    fi
done

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
