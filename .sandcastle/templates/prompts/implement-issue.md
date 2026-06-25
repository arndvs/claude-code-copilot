# TASK

You are implementing GitHub issue #{{ISSUE_NUMBER}}: {{ISSUE_TITLE}}.

- **Branch:** `{{BRANCH}}`

Implement only this issue. Do not pull work from sibling issues or unrelated TODOs.

# CONTEXT

Read the issue before editing:

```
gh issue view {{ISSUE_NUMBER}} --comments
```

Read `CONTEXT.md` and relevant ADRs under `docs/adr/` if they exist.
Explore the codebase and tests that touch the area you will change.

# EXECUTION

Use red-green-refactor where applicable.

1. RED: write one failing test for the smallest behavior slice.
2. GREEN: implement the minimum code to pass.
3. REPEAT until the issue is complete.
4. REFACTOR while keeping tests green.

Before committing, run the relevant project feedback loops. Prefer `pnpm run typecheck` and `pnpm run test` when available.

# COMMIT

Make one or more git commits on `{{BRANCH}}`. Use conventional-commit messages (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`).

Include `Refs #{{ISSUE_NUMBER}}` in each commit body. Do **not** close the issue yourself and do **not** push the branch. The workflow handles pushing and opening the PR.