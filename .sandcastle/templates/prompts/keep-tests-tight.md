# TASK

You are running the scheduled keep-tests-tight pass. Review the repository's test suite against the repo's testing principles and trim low-signal tests down to high-signal coverage.

This is an unattended CI run. There is no user to interview. Your job is to edit, combine, or delete low-signal tests so the suite stays fast, trustworthy, and high-signal.

- **Branch:** `{{BRANCH}}`

# OUT OF SCOPE — VENDORED/PRODUCER-OWNED PATHS

The following paths are **vendored or producer-owned** and are never edited from this repo:

- {{OUT_OF_SCOPE_PATHS}}

Do **NOT** modify, combine, or delete any test or file under these paths. They are re-vendored on every build; local changes would be overwritten upstream and create drift.

# TESTING PRINCIPLES

Read the repo's testing principles from `{{TESTING_PRINCIPLES}}` if the file exists, and apply them strictly.

# METHOD

1. Read `{{CONTEXT_DOC}}` and relevant ADRs under `{{ADR_DIR}}` if they exist.
2. Explore the test suite.
3. Identify low-signal tests: tiny one-assertion tests, duplicate coverage, pinned error strings, edge cases that can't happen, and tests that only assert incidental copy.
4. Edit, combine, or delete them. Keep high-signal end-user-journey tests.

# RULES

- Do **NOT** delete tests that validate real user journeys or documented business rules.
- Do **NOT** touch non-test code. Be read-only on non-test files.
- Run formatting before committing.
- Commit on `{{BRANCH}}` using conventional-commit messages (`test:`, `refactor:`).
- Do **not** push the branch. The workflow pushes and opens the PR.
- Keep your summary, removed/consolidated/kept lists, and diff stat in the session. A follow-up extraction pass will ask you to report the outcome.
