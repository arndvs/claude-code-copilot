# TASK

You are fixing review comments on PR #{{PR_NUMBER}} (branch `{{BRANCH}}`).

These comments have been scored by an automated system and classified as safe to auto-fix. Your job is to make the requested code changes, run tests, and commit.

# COMMENTS TO FIX

Each comment includes the file path, line number, body text, confidence score, and tier.

```json
{{COMMENTS_JSON}}
```

# PROCESS

1. Read each comment carefully. Understand what change is being requested.
2. Make the code changes. Each comment should result in a targeted fix — don't over-engineer.
3. Run the project's test and typecheck scripts before committing.
4. Use conventional-commit messages (`fix:`, `refactor:`, etc.).
5. If a comment is unclear or the fix would break something, skip it — don't force a bad change.

# RULES

- Only modify files referenced by the comments unless a fix requires touching related code.
- Do not refactor beyond what the comment asks for.
- If tests fail after your changes, revert the problematic change and skip that comment.
- Emit the completion signal when done.

<promise>COMPLETE</promise>
