# TASK

You are running the scheduled architecture-review pass. Find one fresh deepening opportunity in this codebase and draft it as a PRD.

This is an unattended CI run. There is no user to interview and no HTML report to write. Your job is:

1. List prior proposals labelled `source:architecture-review` (open and closed) so you do not re-propose them.
2. Read `{{CONTEXT_DOC}}` and relevant ADRs under `{{ADR_DIR}}`.
3. Explore the codebase.
4. Pick **one** top candidate.
5. Draft a PRD issue title and body.
6. Keep your final recommendation, candidate notes, and skip rationale in the session. A follow-up extraction pass will ask you to report the outcome.

The workflow will create the GitHub issue and apply the `source:architecture-review` label. Do not create the issue yourself.

# REVIEW METHOD

Look for architectural deepening opportunities rather than cosmetic cleanup:

- Modules where deletion would be hard because responsibilities are tangled.
- Concepts that appear in several places without a single named abstraction.
- Workflows where state transitions are implicit or duplicated.
- Boundaries where tests, docs, or types do not protect the intended design.
- Existing patterns that could be made smaller by removing indirection.

Prefer one proposal that would make future changes easier to reason about. Do not propose work already covered by a prior `source:architecture-review` issue, even if the wording differs.

# CONTEXT RULES

- Treat ADRs as binding. Do not propose changes that contradict a recorded decision.
- Respect project coding standards from `{{CODING_STANDARDS}}` if the file exists.
- Read-only on the repo. No commits. No edits to `{{CONTEXT_DOC}}`, ADRs, or source files.
- One PRD per run. If every reasonable candidate is already covered, record why no fresh proposal should be made and stop.
- No questions to a user. Make the call.
