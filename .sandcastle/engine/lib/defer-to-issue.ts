import type { ScoredComment } from "./types.js";
import { resolveThread } from "./resolve-threads.js";
import { postThreadReply } from "./post-review.js";
import { shFile } from "./shell-helpers.js";

interface PrContext {
  prNumber: string;
  owner: string;
  repo: string;
}

interface DeferResult {
  issueNumber: number;
  issueUrl: string;
}

/**
 * Create a GitHub issue for a HITL-tier comment that the engine won't auto-fix.
 * Posts a reply on the PR thread linking to the issue, then resolves the thread.
 */
export function deferToIssue(opts: { scored: ScoredComment; pr: PrContext; threadId: string; cwd: string }): DeferResult {
  const { scored, pr, threadId, cwd } = opts;
  const { comment, score, signals } = scored;

  const titleSnippet = comment.body.slice(0, 60).replace(/\n/g, " ");
  const title = `review: ${titleSnippet}`;

  // The shft/hitl labels are review metadata that may not exist in every target
  // repo. Guard on their presence so gh issue create --label fails cleanly when
  // they are absent instead of erroring (or creating issues with no labels).
  const useReviewLabels = reviewLabelsExist({ owner: pr.owner, repo: pr.repo, cwd });
  const labelArgs = useReviewLabels ? ["--label", "shft", "--label", "hitl"] : [];

  const signalList = signals.map((s) => `- ${s.label}: ${s.delta > 0 ? "+" : ""}${s.delta}`).join("\n");

  const body = [
    `## Copilot Review Comment (HITL)`,
    ``,
    `**Score:** ${score}/100 (HITL tier — below auto-fix threshold)`,
    `**PR:** #${pr.prNumber}`,
    comment.path ? `**File:** \`${comment.path}\`` : null,
    comment.line ? `**Line:** ${comment.line}` : null,
    ``,
    `### Comment`,
    ``,
    `> ${comment.body.split("\n").join("\n> ")}`,
    ``,
    `### Score Breakdown`,
    ``,
    signalList,
  ]
    .filter((line) => line !== null)
    .join("\n");

  // Check for existing issue with same title to avoid duplicates
  const existing = findExistingIssue({ title, owner: pr.owner, repo: pr.repo, cwd, useReviewLabels });
  if (existing) {
    postThreadReply({ threadId, body: `Deferred to #${existing.number} — score ${score}/100 (HITL tier)`, cwd });
    resolveThread({ threadId, cwd });
    return { issueNumber: existing.number, issueUrl: existing.url };
  }

  // Create the issue
  const issueUrl = shFile(
    "gh",
    ["issue", "create", "--repo", `${pr.owner}/${pr.repo}`, "--title", title, "--body", body, ...labelArgs],
    cwd,
  ).trim();

  const issueNumber = parseIssueNumber(issueUrl);

  postThreadReply({ threadId, body: `Deferred to #${issueNumber} — score ${score}/100 (HITL tier)`, cwd });
  resolveThread({ threadId, cwd });

  return { issueNumber, issueUrl };
}

function parseIssueNumber(issueUrl: string): number {
  const match = issueUrl.match(/\/(\d+)$/);
  if (!match) {
    throw new Error(`Failed to parse issue number from gh issue create output: ${issueUrl}`);
  }

  return parseInt(match[1]!, 10);
}

function reviewLabelsExist(opts: { owner: string; repo: string; cwd: string }): boolean {
  try {
    const result = shFile("gh", ["label", "list", "--repo", `${opts.owner}/${opts.repo}`, "--json", "name"], opts.cwd);
    const labels = JSON.parse(result) as Array<{ name: string }>;
    return labels.some((l) => l.name === "shft") && labels.some((l) => l.name === "hitl");
  } catch {
    return false;
  }
}

function findExistingIssue(opts: { title: string; owner: string; repo: string; cwd: string; useReviewLabels: boolean }): { number: number; url: string } | null {
  try {
    // Only filter by the review labels when they are known to exist. gh issue
    // list --label with an unknown label silently matches nothing (AND filter),
    // which would defeat dedup and create duplicate issues.
    const labelFilter = opts.useReviewLabels ? ["--label", "shft,hitl"] : [];
    const result = shFile(
      "gh",
      ["issue", "list", "--repo", `${opts.owner}/${opts.repo}`, ...labelFilter, "--state", "open", "--search", opts.title, "--json", "number,url,title", "--limit", "5"],
      opts.cwd,
    );

    const issues = JSON.parse(result) as Array<{ number: number; url: string; title: string }>;
    const match = issues.find((i) => i.title === opts.title);
    return match ?? null;
  } catch {
    return null;
  }
}
