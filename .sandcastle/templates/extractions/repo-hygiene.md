# EMIT STRUCTURED OUTPUT

You have finished the repo-hygiene pass. **Do not explore further or make any changes** — only report the outcome.

End your response with a single `<output>` block. It has one of two shapes.

## Proposed a task this run

<output>
{
  "status": "proposed",
  "title": "Issue title (matches the issue you drafted)",
  "body": "The issue body you drafted.",
  "phase": 1,
  "stack": "astro",
  "oneLineSummary": "One-line description of the task.",
  "candidatesConsidered": ["candidate 1", "candidate 2"]
}
</output>

## Skipped — nothing to propose

<output>
{
  "status": "skipped",
  "reason": "Why no task was proposed (e.g. a task is already open, or the repo is clean)."
}
</output>

Field rules:

- `status` — `"proposed"` or `"skipped"`. Required.
- `title` — required when proposed; ≤256 characters.
- `body` — required when proposed; the full issue body.
- `phase` — required when proposed; integer 0–5.
- `stack` — required when proposed; the detected stack.
- `oneLineSummary` — required when proposed.
- `candidatesConsidered` — required when proposed; non-empty array of strings.
- `reason` — required when skipped.

Do not add fields beyond those listed. The JSON is machine-parsed.
