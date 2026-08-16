#!/usr/bin/env bash
#
# test_proxy_preflight.sh — hermetic tests for proxy_preflight.sh.
#
# Stubs curl via PATH so proxy readiness/model checks run offline. The same
# suite runs against the template script and the installed dogfood copy because
# GitHub Actions execute the installed `.sandcastle/scripts` path.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Resolve the repo root robustly from either the template location
# (shft/templates/scripts) or the installed dogfood location
# (.sandcastle/scripts). Walk up until we find the .git marker. Use -e
# (exists) rather than -d (directory) so git worktrees/submodules, where
# .git is a file, are also recognized as the repo root.
ROOT="$(cd "$SCRIPT_DIR" && while [[ ! -e .git && "$PWD" != "/" ]]; do cd ..; done && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$1"; }

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

STUB_DIR="$TMPDIR_ROOT/stubs"
WORK_DIR="$TMPDIR_ROOT/work"
mkdir -p "$STUB_DIR" "$WORK_DIR"

cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
auth=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  if [ "$prev" = "-H" ] && [[ "$arg" == Authorization:* ]]; then
    auth="$arg"
  fi
  prev="$arg"
done
url="${@: -1}"
if [[ "$url" == */health/readiness ]]; then
  [ -n "$out" ] && printf '%s' "${STUB_READY_BODY:-OK}" > "$out"
  printf '%s' "${STUB_READY_CODE:-200}"
elif [[ "$url" == */v1/models ]]; then
  [ -n "${STUB_AUTH_CAPTURE:-}" ] && printf '%s' "$auth" > "$STUB_AUTH_CAPTURE"
  if [ -n "$out" ]; then
    if [ -n "${STUB_MODELS_BODY+x}" ]; then
      printf '%s' "$STUB_MODELS_BODY" > "$out"
    else
      printf '%s' '{"data":[{"id":"claude-sonnet-4-6"}]}' > "$out"
    fi
  fi
  printf '%s' "${STUB_MODELS_CODE:-200}"
else
  printf '404'
fi
STUB
chmod +x "$STUB_DIR/curl"

write_config() {
  local model="${1:-claude-sonnet-4-6}"
  local proxy="${2:-true}"
  printf '{"model":"%s","proxy":%s}\n' "$model" "$proxy" > "$WORK_DIR/sandcastle.config.json"
}

run_preflight() {
  local probe="$1"
  local out_file="$TMPDIR_ROOT/github-output"
  rm -f "$out_file"
  (
    cd "$WORK_DIR"
    GITHUB_OUTPUT="$out_file" PATH="$STUB_DIR:$PATH" bash "$probe" >/dev/null
  )
  cat "$out_file"
}

assert_field() {
  local label="$1" output="$2" key="$3" expected="$4"
  if printf '%s\n' "$output" | grep -qx "$key=$expected"; then
    pass "$label"
  else
    fail "$label"
  fi
}

run_suite() {
  local label="$1"
  local probe="$2"

  if [[ ! -f "$probe" ]]; then
    fail "$label script exists"
    return
  fi

  write_config "claude-sonnet-4-6" "false"
  out=$(ANTHROPIC_BASE_URL="" ANTHROPIC_AUTH_TOKEN="" ANTHROPIC_API_KEY="direct-key" run_preflight "$probe")
  assert_field "$label direct provider mode runs only when proxy=false" "$out" "should_run" "true"
  assert_field "$label direct provider mode reason" "$out" "reason" "direct-provider"

  out=$(ANTHROPIC_BASE_URL="" ANTHROPIC_AUTH_TOKEN="" ANTHROPIC_API_KEY="" run_preflight "$probe")
  assert_field "$label direct provider missing key skips" "$out" "should_run" "false"
  assert_field "$label direct provider missing key reason" "$out" "reason" "missing-direct-provider-key"

  write_config
  out=$(ANTHROPIC_BASE_URL="" ANTHROPIC_AUTH_TOKEN="" run_preflight "$probe")
  assert_field "$label proxy mode missing base URL skips" "$out" "should_run" "false"
  assert_field "$label proxy mode missing base URL reason" "$out" "reason" "missing-proxy-base-url"

  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="" run_preflight "$probe")
  assert_field "$label missing proxy token skips" "$out" "should_run" "false"
  assert_field "$label missing proxy token reason" "$out" "reason" "missing-proxy-token"

  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="secret-token" STUB_READY_CODE=503 run_preflight "$probe")
  assert_field "$label readiness failure skips" "$out" "should_run" "false"
  assert_field "$label readiness failure reason" "$out" "reason" "proxy-not-ready"

  auth_capture="$TMPDIR_ROOT/$label-auth-header.txt"
  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="secret-token" STUB_AUTH_CAPTURE="$auth_capture" run_preflight "$probe")
  assert_field "$label available model runs" "$out" "should_run" "true"
  assert_field "$label available model reason" "$out" "reason" "ok"
  if [ "$(cat "$auth_capture" 2>/dev/null || true)" = "Authorization: Bearer secret-token" ] && ! printf '%s\n' "$out" | grep -qF "secret-token"; then
    pass "$label models probe sends bearer token without emitting it"
  else
    fail "$label models probe auth header"
  fi

  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="secret-token" STUB_MODELS_BODY='{"data":[{"id":"other-model"}]}' run_preflight "$probe")
  assert_field "$label missing configured model skips" "$out" "should_run" "false"
  assert_field "$label missing configured model reason" "$out" "reason" "model-unavailable"

  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="secret-token" STUB_MODELS_CODE=401 run_preflight "$probe")
  assert_field "$label models auth failure skips" "$out" "should_run" "false"
  assert_field "$label models auth failure reason" "$out" "reason" "proxy-auth-failed"

  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="secret-token" STUB_MODELS_CODE=404 run_preflight "$probe")
  assert_field "$label models probe unavailable still runs after readiness" "$out" "should_run" "true"
  assert_field "$label models probe unavailable reason" "$out" "reason" "models-probe-unavailable"

  printf '{}\n' > "$WORK_DIR/sandcastle.config.json"
  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="secret-token" run_preflight "$probe")
  assert_field "$label missing model config uses default model" "$out" "should_run" "false"
  assert_field "$label missing model config probes default model" "$out" "reason" "model-unavailable"

  # SANDCASTLE_CONFIG_PATH override wins over the workspace-root config.
  write_config "claude-sonnet-4-6" "true"
  override_path="$TMPDIR_ROOT/$label-override.json"
  printf '{"model":"claude-sonnet-4-6","proxy":false}\n' > "$override_path"
  out=$(ANTHROPIC_BASE_URL="" ANTHROPIC_AUTH_TOKEN="" ANTHROPIC_API_KEY="direct-key" \
    SANDCASTLE_CONFIG_PATH="$override_path" run_preflight "$probe")
  assert_field "$label override path wins over workspace config" "$out" "should_run" "true"
  assert_field "$label override path reason" "$out" "reason" "direct-provider"

  # SANDCASTLE_CONFIG_PATH pointing at a nonexistent path falls back to the
  # existing "missing config" default behavior (proxy=true / default model).
  out=$(ANTHROPIC_BASE_URL="https://proxy.test/v1" ANTHROPIC_AUTH_TOKEN="secret-token" \
    SANDCASTLE_CONFIG_PATH="$TMPDIR_ROOT/$label-does-not-exist.json" run_preflight "$probe")
  assert_field "$label missing override path falls back to default model" "$out" "should_run" "false"
  assert_field "$label missing override path probes default model" "$out" "reason" "model-unavailable"
}

echo "── proxy_preflight.sh tests ──"
run_suite "template" "$SCRIPT_DIR/proxy_preflight.sh"
run_suite "installed" "$ROOT/.sandcastle/scripts/proxy_preflight.sh"

echo ""
printf "  \033[32m%d passed\033[0m  \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
