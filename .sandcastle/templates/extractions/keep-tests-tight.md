# EMIT STRUCTURED OUTPUT

You have finished the keep-tests-tight pass. **Do not explore further or make any changes** — only report the outcome.

End your response with a single `<output>` block. It has one of two shapes.

## Changed tests this run

<output>
{
  "status": "changed",
  "summary": "One-paragraph summary of what you trimmed and why.",
  "removed": ["path/to/deleted-test.test.ts"],
  "consolidated": ["path/to/combined-test.test.ts"],
  "kept": ["path/to/high-signal-journey.test.ts"],
  "diffStat": "10 files changed, 120 insertions(+), 300 deletions(-)"
}
</output>

## No changes needed

<output>
{
  "status": "no-changes",
  "reason": "Why no test changes were needed (e.g. the suite is already high-signal)."
}
</output>

Field rules:

- `status` — `"changed"` or `"no-changes"`. Required.
- `summary` — required when changed; a short paragraph.
- `removed` — required when changed; array of file paths deleted.
- `consolidated` — required when changed; array of file paths combined/edited.
- `kept` — required when changed; array of high-signal file paths you deliberately kept.
- `diffStat` — required when changed; the `git diff --stat` line for the run.
- `reason` — required when no-changes.

Do not add fields beyond those listed. The JSON is machine-parsed.
