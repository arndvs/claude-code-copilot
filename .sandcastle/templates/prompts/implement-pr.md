# TASK

You are addressing reviewer feedback on PR #{{PR_NUMBER}} (branch `{{BRANCH}}`).

Your job is to read the unresolved conversation on this PR, decide what (if anything) to change in the code, make those changes, and explain yourself by commenting back where useful.

# CONTEXT

<linked-issue>

{{ISSUE_TITLE}}

!`gh issue view {{ISSUE_NUMBER}} --comments 2>/dev/null || echo "(No linked issue)"`

</linked-issue>

<diff-to-main>

!`gh pr diff {{PR_NUMBER}}`

</diff-to-main>

<pr-comments>

The unresolved conversation on this PR. Tagged by surface:

- `issue_comment` — top-level PR conversation comment.
- `review_thread` — inline thread anchored to a file + line. Only **unresolved** threads are included. Each comment has a `commentId` you can reply to in-thread.
- `review_summary` — top-level body of a submitted review.

Not everything here is necessarily actionable — reviewers may leave context, questions, asides, or things they meant to resolve. Use your judgement. **Do not treat unresolved == must-action.**

```json
{{PR_COMMENTS_JSON}}
```

</pr-comments>

# PROCESS

1. Read the conversation. For each item, classify it: code change needed, reply needed (question / disagreement / clarification), or neither.
2. Make the code changes you decided on. Run the project's test and typecheck scripts before committing. Use conventional-commit messages (`feat:`, `fix:`, `refactor:`, etc.).
3. If you made no changes that's fine — only commit when there's a real diff.
4. Keep track of any replies or new inline comments that would help reviewers understand what you changed or why you did not change something. A follow-up extraction pass will ask you to report them.

You do not have to reply to every thread. Reply only where a reply adds value: confirming what you changed, explaining why you chose not to make a requested change, answering a question, or pointing out something the reviewer should look at. Silence is fine for context-only comments.

You cannot resolve threads. Resolution is the reviewer's job.
