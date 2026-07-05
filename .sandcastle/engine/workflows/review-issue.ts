import { shFile } from "../lib/shell-helpers.js";

/**
 * Review the labeled issue entrypoint without touching PR-only plumbing.
 *
 * The GitHub Actions state machine advances successful runs to
 * `agent:review`, where `plan-issue` performs the PRD-to-issues breakdown.
 */
export function runReviewIssue(opts: { issueNumber: string; repoDir: string }): void {
  console.log(`[review-issue] Reading issue #${opts.issueNumber}...`);

  const issueJson = shFile("gh", ["issue", "view", opts.issueNumber, "--json", "title,state"], opts.repoDir);

  const issue = JSON.parse(issueJson) as { title: string; state: string };
  console.log(`[review-issue] Issue: ${issue.title}`);
  console.log(`[review-issue] State: ${issue.state}`);
}