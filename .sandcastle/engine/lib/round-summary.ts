import { shFile } from "./shell-helpers.js";
import type { Tier } from "./types.js";

interface CommentResult {
  body: string;
  score: number;
  tier: Tier;
  action: "fixed" | "deferred" | "skipped";
  issueNumber?: number;
}

interface RoundSummaryOpts {
  owner: string;
  repo: string;
  prNumber: string;
  round: number;
  maxRounds: number;
  results: CommentResult[];
  cwd: string;
}

/**
 * Post a summary comment on a PR after each round of review processing.
 * Shows what was fixed, deferred, and skipped in a compact table.
 */
export function postRoundSummary(opts: RoundSummaryOpts): void {
  const { owner, repo, prNumber, round, maxRounds, results, cwd } = opts;

  const fixed = results.filter((r) => r.action === "fixed");
  const deferred = results.filter((r) => r.action === "deferred");
  const skipped = results.filter((r) => r.action === "skipped");

  const lines: string[] = [
    `### 🔄 Review Round ${round}/${maxRounds}`,
    "",
    `| Comment | Score | Tier | Action |`,
    `|---------|-------|------|--------|`,
  ];

  for (const r of results) {
    const snippet = r.body.slice(0, 50).replace(/\|/g, "\\|").replace(/\n/g, " ");
    const actionLabel = formatAction(r);
    lines.push(`| ${snippet} | ${r.score} | ${r.tier} | ${actionLabel} |`);
  }

  lines.push("");
  lines.push(`**${fixed.length}** fixed ✅ · **${deferred.length}** deferred 📋 · **${skipped.length}** skipped ⏭️`);

  if (round >= maxRounds && skipped.length > 0) {
    lines.push("");
    lines.push(`> ⚠️ Round cap reached. ${skipped.length} unresolved comment(s) remain.`);
  }

  const body = lines.join("\n");

  try {
    shFile("gh", ["pr", "comment", prNumber, "--repo", `${owner}/${repo}`, "--body", body], cwd);
    console.log(`Posted round ${round} summary on PR #${prNumber}`);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`Failed to post round summary on PR #${prNumber}: ${message}`);
  }
}

function formatAction(r: CommentResult): string {
  switch (r.action) {
    case "fixed":
      return "Fixed ✅";
    case "deferred":
      return r.issueNumber ? `Deferred → #${r.issueNumber} 📋` : "Deferred 📋";
    case "skipped":
      return "Skipped ⏭️";
  }
}
