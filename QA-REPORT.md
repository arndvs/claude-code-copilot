# HITL QA Report — Audit Remediation

**Date:** 2026-06-04
**Branch:** `ai/fix/harden-secret-handling`
**PRD:** #3
**QA Issue:** #11

## Results: All Checks Pass

| # | Check | Result |
|---|-------|--------|
| 1 | Full diff contains no accidental routing/model changes | PASS |
| 2 | Python compile checks pass | PASS |
| 3 | Bash syntax checks pass | PASS |
| 4 | Security regression script passes (6/6 tests) | PASS |
| 5 | `git diff --check` passes | PASS |
| 6 | No command output contains real `.env` values | PASS |
| 7 | `claude-status` remains useful while redacting secrets | PASS |
| 8 | Optional live proxy smoke test | SKIPPED (no OAuth) |

## Details

### 1. No routing/model changes

Only change to `litellm_config.yaml`: removed `set_verbose: true`. All model entries
(sonnet, haiku-to-sonnet fallback, opus 4.6, opus 4.7, wildcard) are identical to pre-audit.

### 2-3. Syntax checks

- `py_compile`: `claude_enable.py`, `claude_disable.py` — both pass
- `bash -n`: `list-copilot-models.sh`, `start_proxy.sh`, `test_security.sh` — all pass

### 4. Security regression tests

```
Test 1: claude-status redacts secret-like env vars
  PASS: All secret-like keys redacted; non-secret keys preserved
Test 1b: invalid settings JSON does not print file contents
  PASS: Invalid JSON handled safely
Test 2: claude_enable.py reads master key from env
  PASS: Master key read from env and written to settings
  PASS: claude_enable.py fails with clear error when key missing
Test 3: Copilot token not exposed in curl argv
  PASS: Copilot token not present in curl command-line arguments
Test 3b: Empty Copilot token fails before curl
  PASS: Empty Copilot token file fails before curl is invoked
Results: 6 passed, 0 failed
```

### 5. git diff --check

No whitespace errors across all 7 security commits.

### 6. No .env values in output

Code review confirms:
- `claude_enable.py` reads key from env, never prints it
- `list-copilot-models.sh` writes token to chmod-600 temp file, not stdout
- `claude-status` redacts secret-like env vars with bounded credential tokens (`TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `CREDENTIAL`, `AUTH`)

### 7. claude-status usefulness

Redaction preserves:
- Routing mode (proxy vs Anthropic direct)
- Proxy URL (`ANTHROPIC_BASE_URL`)
- Proxy health status
- All non-secret configuration values

## Follow-up Note

`make test` target still passes master key via `curl -H` argv. This predates the audit
and was not in scope (issues #6-#7 targeted `claude_enable.py` and `list-copilot-models.sh`
specifically). Consider hardening in a future issue.

## Issues Ready to Close

All prerequisite issues have fix commits landed and verified:
- #4 — Disable verbose LiteLLM logging (commit `9c01cf1`)
- #5 — Redact Claude status output broadly (commit `3425468`)
- #6 — Master key via env instead of argv (commit `b020218`)
- #7 — Copilot token via curl config file (commit `7f716da`)
- #8 — Remove stale research notes artifact (commit `8626e55`)
- #9 — Security regression tests (commit `7f46b87`)
- #10 — Docs updated for env-based behavior (commit `1b69a68`)
- #11 — This QA report
- #3 — Parent PRD (all children complete)
