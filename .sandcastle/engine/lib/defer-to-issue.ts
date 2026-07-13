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
  const existing = findExistingIssue({ title, owner: pr.owner, repo: pr.repo, cwd });
  if (existing) {
    postThreadReply({ threadId, body: `Deferred to #${existing.number} — score ${score}/100 (HITL tier)`, cwd });
    resolveThread({ threadId, cwd });
    return { issueNumber: existing.number, issueUrl: existing.url };
  }

  // Create the issue
  const issueUrl = shFile(
    "gh",
    ["issue", "create", "--repo", `${pr.owner}/${pr.repo}`, "--title", title, "--body", body, "--label", "shft", "--label", "hitl"],
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

function findExistingIssue(opts: { title: string; owner: string; repo: string; cwd: string }): { number: number; url: string } | null {
  try {
    const result = shFile(
      "gh",
      ["issue", "list", "--repo", `${opts.owner}/${opts.repo}`, "--label", "shft,hitl", "--state", "open", "--search", opts.title, "--json", "number,url,title", "--limit", "5"],
      opts.cwd,
    );

    const issues = JSON.parse(result) as Array<{ number: number; url: string; title: string }>;
    const match = issues.find((i) => i.title === opts.title);
    return match ?? null;
  } catch {
    return null;
  }
}
