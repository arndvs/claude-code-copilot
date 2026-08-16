#!/usr/bin/env bash
# test_config_generator.sh — Verify litellm_config.yaml matches generate_config.py
#
# Acceptance criteria (from issue #130):
#   1. scripts/generate_config.py exists and is runnable
#   2. Running it produces YAML that parses
#   3. The generated YAML matches the committed litellm_config.yaml (no drift)
#   4. The four editor headers appear in exactly one place (the generator)
#
# Usage: bash tests/test_config_generator.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

GENERATOR="scripts/generate_config.py"
CONFIG="litellm_config.yaml"

# ── Test 1: generator exists and is runnable ──────────────────
echo "Test 1: generator exists and is runnable"
if [ ! -f "$GENERATOR" ]; then
    fail "$GENERATOR not found"
else
    if python3 "$GENERATOR" >/dev/null 2>&1; then
        pass "$GENERATOR runs successfully"
    else
        fail "$GENERATOR failed to run"
    fi
fi

# ── Test 2: generated YAML parses ─────────────────────────────
echo "Test 2: generated YAML parses"
if python3 -c "
import sys, yaml
sys.path.insert(0, 'scripts')
import generate_config
data = yaml.safe_load(generate_config.generate_config())
assert isinstance(data, dict), 'generated config did not parse as a mapping'
print('OK')
" >/dev/null 2>&1; then
    pass "generated YAML parses as a mapping"
else
    fail "generated YAML did not parse"
fi

# ── Test 3: generated YAML matches committed config (no drift) ─
echo "Test 3: generated YAML matches committed config"
if python3 -c "
import sys, yaml
sys.path.insert(0, 'scripts')
import generate_config
gen = yaml.safe_load(generate_config.generate_config())
committed = yaml.safe_load(open('$CONFIG', encoding='utf-8'))
assert gen == committed, 'DRIFT: litellm_config.yaml differs from generator output'
print('OK')
" >/dev/null 2>&1; then
    pass "committed $CONFIG matches generator output"
else
    fail "DRIFT: $CONFIG differs from generator output — run 'make generate-config'"
fi

# ── Test 4: editor headers defined once (in the generator) ─────
echo "Test 4: editor headers defined once in the generator"
if grep -q 'Editor-Version' "$GENERATOR" \
   && grep -q 'Editor-Plugin-Version' "$GENERATOR" \
   && grep -q 'Copilot-Integration-Id' "$GENERATOR" \
   && grep -q 'User-Agent' "$GENERATOR"; then
    pass "all four editor headers defined in $GENERATOR"
else
    fail "one or more editor headers missing from $GENERATOR"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
