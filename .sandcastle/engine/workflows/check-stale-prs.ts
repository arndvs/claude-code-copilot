import { appendFileSync } from "node:fs";
import { shFile } from "../lib/shell-helpers.js";

interface PullRequestSummary {
  number: number;
  title: string;
  updatedAt: string;
  url: string;
  isDraft: boolean;
  author?: { login?: string };
}

export function runCheckStalePrs(opts: { repoDir: string; now?: Date; staleDays?: number }): void {
  const repo = process.env["GITHUB_REPOSITORY"];
  if (!repo) throw new Error("GITHUB_REPOSITORY environment variable is required");

  const staleDays = opts.staleDays ?? parseStaleDays(process.env["STALE_PR_DAYS"]);
  validateStaleDays(staleDays);
  const cutoff = new Date((opts.now ?? new Date()).getTime() - staleDays * 24 * 60 * 60 * 1000);
  const prs = listOpenPullRequests({ repo, repoDir: opts.repoDir });
  const stale = prs.filter((pr) => new Date(pr.updatedAt).getTime() <= cutoff.getTime());

  const lines = [
    `# Stale PR check`,
    ``,
    `Threshold: no updates for ${staleDays} day(s), cutoff ${cutoff.toISOString()}.`,
    ``,
    stale.length === 0 ? `No stale open PRs found.` : `Found ${stale.length} stale open PR(s):`,
    ...stale.map((pr) => `- #${pr.number} ${pr.title} (${pr.isDraft ? "draft" : "ready"}) — last updated ${pr.updatedAt} — ${pr.url}`),
  ];
  const report = lines.join("\n");

  console.log(report);
  const summaryPath = process.env["GITHUB_STEP_SUMMARY"];
  if (summaryPath) {
    appendFileSync(summaryPath, `${report}\n`, "utf8");
  }
}

function parseStaleDays(raw: string | undefined): number {
  if (!raw) return 14;
  const parsed = Number.parseInt(raw, 10);
  if (!isPositiveInteger(parsed)) {
    throw new Error(`STALE_PR_DAYS must be a positive integer, got: ${raw}`);
  }
  return parsed;
}

function validateStaleDays(staleDays: number): void {
  if (!isPositiveInteger(staleDays)) {
    throw new Error(`staleDays must be a positive integer, got: ${String(staleDays)}`);
  }
}

function isPositiveInteger(value: number): boolean {
  return Number.isInteger(value) && value > 0;
}

function listOpenPullRequests(opts: { repo: string; repoDir: string }): PullRequestSummary[] {
  const output = shFile(
    "gh",
    ["pr", "list", "--state", "open", "--limit", "1000", "--json", "number,title,updatedAt,url,isDraft,author", "-R", opts.repo],
    opts.repoDir,
  );
  return JSON.parse(output) as PullRequestSummary[];
}
