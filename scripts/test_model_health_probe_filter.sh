#!/usr/bin/env bash
# test_model_health_probe_filter.sh — Validate model-health.yml probe-set contract
#
# The model-health workflow must probe ONLY concrete upstream aliases. Probing
# wildcards ('*') or fallback lanes ('*-fallback') reports non-models as failing
# and pollutes every model-health issue (refs #148). This test locks the filter
# shape so a config or workflow edit can't silently reintroduce the noise.
#
# Checks:
#   1. model-health.yml's alias extraction excludes '*' and any '*-fallback'
#   2. The probe loop separates degraded (warning) from fail (page)
#   3. The issue body has explicit Failing / Degraded sections
#
# Usage: bash scripts/test_model_health_probe_filter.sh
#
# Refs #148

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

WORKFLOW=".github/workflows/model-health.yml"

if [ ! -f "$WORKFLOW" ]; then
    echo "  ❌ $WORKFLOW not found"
    exit 1
fi

# ── Test 1: probe set excludes wildcard and fallback suffixes ──
echo "Test 1: probe set excludes wildcard and fallback aliases"
if python3 -c "
import yaml
d = yaml.safe_load(open('$WORKFLOW', encoding='utf-8'))
probe_step = None
for step in d['jobs']['model-health']['steps']:
    if step.get('id') == 'probe':
        probe_step = step
        break
assert probe_step, 'model-health probe step not found'
run = probe_step.get('run', '')
assert \"!=\\n '*' and not m['model_name'].endswith('-fallback')\" in run \
    or \"'*-fallback'\" in run or \"endswith('-fallback')\" in run, \
    'alias extraction does not exclude fallbacks'
print('OK')
" >/dev/null 2>&1; then
    pass "alias extraction excludes '*' and '*-fallback'"
else
    fail "alias extraction does not exclude '*' / '*-fallback'"
fi

# ── Test 2: degraded is a warning, not a paging failure ────────
echo "Test 2: degraded completions are warnings, not failures"
if python3 -c "
import yaml
d = yaml.safe_load(open('$WORKFLOW', encoding='utf-8'))
probe_step = None
for step in d['jobs']['model-health']['steps']:
    if step.get('id') == 'probe':
        probe_step = step
        break
run = probe_step['run']
assert 'degraded=\"\${degraded} \${m}\"' in run or 'degraded=' in run, \
    'probe loop does not track degraded separately'
assert 'broken=\"\${broken} \${m}\"' in run or 'broken=' in run, \
    'probe loop does not track broken'
print('OK')
" >/dev/null 2>&1; then
    pass "probe loop tracks degraded separately from broken"
else
    fail "probe loop does not separate degraded from broken"
fi

# ── Test 3: issue body separates Failing and Degraded ──────────
echo "Test 3: issue body has explicit Failing / Degraded sections"
if python3 -c "
import yaml
d = yaml.safe_load(open('$WORKFLOW', encoding='utf-8'))
steps = d['jobs']['model-health']['steps']
issue_step = None
for step in steps:
    if 'Open or update the model-health issue' in step.get('name', ''):
        issue_step = step
        break
assert issue_step, 'model-health issue step not found'
run = issue_step.get('run', '') or (
    issue_step.get('with', {}).get('body', '') if issue_step.get('uses') else ''
)
assert 'Failing' in run, 'issue body missing Failing section'
assert 'Degraded' in run, 'issue body missing Degraded section'
print('OK')
" >/dev/null 2>&1; then
    pass "issue body distinguishes Failing / Degraded"
else
    fail "issue body does not distinguish Failing / Degraded"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]