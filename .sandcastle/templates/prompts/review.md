# TASK

You are reviewing PR #{{PR_NUMBER}} in this repository.

Your job is to perform a thorough code review: find bugs, logic errors, edge cases, security issues, and integration risks. Post your findings as a structured GitHub review.

# CONTEXT

<diff>

!`gh pr diff {{PR_NUMBER}}`

</diff>

<existing-threads>

Existing review threads on this PR (resolved and unresolved). Do not duplicate findings that are already covered. You may reply to unresolved threads if you have additional context.

```json
{{PR_COMMENTS_JSON}}
```

</existing-threads>

# REVIEW METHODOLOGY

## What to look for

1. **Correctness** — Logic errors, off-by-one, null/undefined handling, wrong types, missing awaits
2. **Edge cases** — Empty arrays, missing keys, concurrent access, error paths not tested
3. **Security** — Injection (SQL, command, XSS), secrets in code, unsafe deserialization, unvalidated input at system boundaries
4. **Integration risks** — Breaking changes to shared interfaces, missing migration steps, dependency version conflicts
5. **Spec verification** — Does the code actually fulfill the PR description / linked issue requirements?

## What NOT to comment on

- Style preferences already enforced by linters/formatters
- Nitpicks that don't affect correctness or maintainability
- Suggestions for future work unrelated to this PR
- Code outside the diff unless it's directly affected by the changes

## Severity guide

Use these prefixes in your comment bodies:
- `🔴 bug:` — Likely incorrect behavior
- `🟡 issue:` — Potential problem or missed edge case
- `💭 question:` — Clarification needed before approving
- `💡 suggestion:` — Optional improvement, take it or leave it

# OUTPUT

Emit a single `<output>` block as the **last thing** in your response. Valid JSON, field names exact.

## Example

<output>
{
  "summary": "Overall solid implementation. Found one bug in the error handling path and a potential race condition in the cache invalidation. Two minor suggestions included.",
  "inlineComments": [
    {
      "path": "src/services/cache.ts",
      "line": 42,
      "body": "🔴 bug: `delete` is called before the async write completes — if the write fails, the cache entry is already gone. Await the write or move the delete into the `.then()` callback."
    },
    {
      "path": "src/api/handler.ts",
      "line": 15,
      "body": "🟡 issue: `req.body` is used without validation. If the upstream proxy strips the content-type header, this will silently be `undefined`."
    }
  ],
  "replies": [
    {
      "commentId": "PRRC_kwDOPSEf9c8AAAABX1234",
      "body": "Agree — the guard added in the latest commit doesn't cover the `null` case mentioned here."
    }
  ]
}
</output>

## Empty output

If the code looks correct and you have no findings:

<output>
{ "summary": "LGTM — no issues found.", "inlineComments": [], "replies": [] }
</output>

## Field reference

| Field                      | Type    | Required | Notes                                                                 |
| -------------------------- | ------- | -------- | --------------------------------------------------------------------- |
| `summary`                  | string  | **yes**  | Overall review summary. Becomes the review body on GitHub.            |
| `inlineComments`           | array   | no       | Inline comments anchored to specific diff lines.                     |
| `inlineComments[].path`    | string  | **yes**  | Relative file path.                                                   |
| `inlineComments[].line`    | integer | **yes**  | Line number on the selected `side`. Dropped if not in diff.          |
| `inlineComments[].side`    | string  | no       | `RIGHT` for added/context lines, `LEFT` for removed lines. Defaults to `RIGHT`. |
| `inlineComments[].body`    | string  | **yes**  | Markdown comment body. Use severity prefixes above.                  |
| `replies`                  | array   | no       | Replies to existing unresolved review threads.                       |
| `replies[].commentId`      | string  | **yes**  | Must match a `commentId` from `<existing-threads>`. Do not invent.   |
| `replies[].body`           | string  | **yes**  | Markdown reply.                                                       |

Do not add fields not listed above.
