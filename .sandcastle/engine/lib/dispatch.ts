import type { CliArgs } from "./parse-cli-args.js";
import { outputDirPath, shFileInherit } from "./shell-helpers.js";
import { join } from "node:path";
import { StructuredOutputError } from "@ai-hero/sandcastle";

export type WorkflowRunner = (opts: { args: CliArgs; repoDir: string; templatesDir: string }) => Promise<void>;

const MERGE_PR_TIMEOUT_MS = 30 * 60 * 1000;

const workflows: Record<string, WorkflowRunner> = {
  "review-issue": async ({ args, repoDir }) => {
    if (!args.issue) throw new Error("review-issue requires --issue <number>");
    const { runReviewIssue } = await import("../workflows/review-issue.js");
    await runReviewIssue({ issueNumber: args.issue, repoDir });
  },

  "plan-issue": async ({ args, repoDir, templatesDir }) => {
    if (!args.issue) throw new Error("plan-issue requires --issue <number>");
    const { runToIssuesPrd } = await import("../workflows/to-issues-prd.js");
    await runToIssuesPrd({ issueNumber: args.issue, repoDir, templatesDir, dryRun: args.dryRun });
  },

  "implement-issue": async ({ args, repoDir, templatesDir }) => {
    if (!args.issue) throw new Error("implement-issue requires --issue <number>");
    if (!args.issueTitle) throw new Error("implement-issue requires --issue-title <text>");
    if (!args.branch) throw new Error("implement-issue requires --branch <ref>");
    const { runImplementIssue } = await import("../workflows/implement-issue.js");
    await runImplementIssue({ issueNumber: args.issue, issueTitle: args.issueTitle, branch: args.branch, repoDir, templatesDir });
  },

  "fix-pr-feedback": async ({ args, repoDir }) => {
    if (!args.pr) throw new Error("fix-pr-feedback requires --pr <number>");
    const { runAddressReview } = await import("../workflows/address-review.js");
    await runAddressReview({ prNumber: args.pr, repoDir, round: 1, maxRounds: 3 });
  },

  "address-review": async ({ args, repoDir }) => {
    if (!args.pr) throw new Error("address-review requires --pr <number>");
    const round = parseRequiredPositiveInt(args.round, "--round");
    const maxRounds = parseRequiredPositiveInt(args.maxRounds, "--max-rounds");
    const { runAddressReview } = await import("../workflows/address-review.js");
    await runAddressReview({ prNumber: args.pr, repoDir, round, maxRounds });
  },

  "merge-pr": async ({ args, repoDir }) => {
    if (!args.pr) throw new Error("merge-pr requires --pr <number>");
    const repo = process.env["GITHUB_REPOSITORY"];
    if (!repo) throw new Error("GITHUB_REPOSITORY environment variable is required");
    shFileInherit("gh", ["pr", "merge", args.pr, "--squash", "--delete-branch", "-R", repo], {
      cwd: repoDir,
      timeout: MERGE_PR_TIMEOUT_MS,
    });
  },

  "write-pr": async ({ args, repoDir, templatesDir }) => {
    if (!args.issue) throw new Error("write-pr requires --issue <number>");
    if (!args.issueTitle) throw new Error("write-pr requires --issue-title <text>");
    if (!args.branch) throw new Error("write-pr requires --branch <ref>");
    const { runWritePr } = await import("../workflows/write-pr.js");
    const result = await runWritePr({ issueNumber: args.issue, issueTitle: args.issueTitle, branch: args.branch, repoDir, templatesDir });
    const fs = await import("node:fs");
    const outputDir = outputDirPath();
    fs.writeFileSync(join(outputDir, "pr_title.txt"), result.prTitle);
    fs.writeFileSync(join(outputDir, "pr_description.txt"), result.prDescription);
  },

  "write-prd-pr": async ({ args, repoDir, templatesDir }) => {
    if (!args.prdNumber) throw new Error("write-prd-pr requires --prd-number <number>");
    if (!args.prdTitle) throw new Error("write-prd-pr requires --prd-title <text>");
    const { runWritePr } = await import("../workflows/write-pr.js");
    const result = await runWritePr({ prdNumber: args.prdNumber, prdTitle: args.prdTitle, repoDir, templatesDir });
    const fs = await import("node:fs");
    const outputDir = outputDirPath();
    fs.writeFileSync(join(outputDir, "pr_title.txt"), result.prTitle);
    fs.writeFileSync(join(outputDir, "pr_description.txt"), result.prDescription);
  },

  "update-branch": async ({ args, repoDir, templatesDir }) => {
    if (!args.pr) throw new Error("update-branch requires --pr <number>");
    if (!args.branch) throw new Error("update-branch requires --branch <ref>");
    if (!args.baseRef) throw new Error("update-branch requires --base-ref <ref>");
    const { runUpdateBranch } = await import("../workflows/update-branch.js");
    const result = await runUpdateBranch({ prNumber: args.pr, branch: args.branch, baseRef: args.baseRef, repoDir, templatesDir });
    const fs = await import("node:fs");
    const outputDir = outputDirPath();
    fs.writeFileSync(join(outputDir, "comment.md"), result.comment);
    fs.writeFileSync(join(outputDir, "should_push.txt"), result.shouldPush ? "true" : "false");
  },

  "implement-prd": async ({ args, repoDir, templatesDir }) => {
    if (!args.prdNumber) throw new Error("implement-prd requires --prd-number <number>");
    if (!args.prdTitle) throw new Error("implement-prd requires --prd-title <text>");
    if (!args.subIssueNumber) throw new Error("implement-prd requires --sub-issue-number <number>");
    if (!args.subIssueTitle) throw new Error("implement-prd requires --sub-issue-title <text>");
    if (!args.branch) throw new Error("implement-prd requires --branch <ref>");
    const { runImplementPrd } = await import("../workflows/implement-prd.js");
    await runImplementPrd({
      prdNumber: args.prdNumber,
      prdTitle: args.prdTitle,
      subIssueNumber: args.subIssueNumber,
      subIssueTitle: args.subIssueTitle,
      branch: args.branch,
      repoDir,
      templatesDir,
    });
  },

  "architecture-review": async ({ repoDir, templatesDir }) => {
    const { runArchitectureReview } = await import("../workflows/architecture-review.js");
    const result = await runArchitectureReview({ repoDir, templatesDir });
    const fs = await import("node:fs");
    const outputDir = outputDirPath();
    fs.writeFileSync(join(outputDir, "architecture_review_output.json"), JSON.stringify(result, null, 2));
    if (result.status === "proposed") {
      fs.writeFileSync(join(outputDir, "prd_title.txt"), result.title);
      fs.writeFileSync(join(outputDir, "prd_body.md"), result.body);
    }
  },

  "check-stale-prs": async ({ repoDir }) => {
    const { runCheckStalePrs } = await import("../workflows/check-stale-prs.js");
    await runCheckStalePrs({ repoDir });
  },
};

export const WORKFLOW_NAMES = Object.keys(workflows);

export function resolveWorkflow(name: string): WorkflowRunner | undefined {
  const runner = workflows[name];
  return runner ? (opts) => runWorkflow(name, runner, opts) : undefined;
}

/** Wrap a workflow runner with centralised StructuredOutputError handling. */
export async function runWorkflow(
  name: string,
  runner: WorkflowRunner,
  opts: { args: CliArgs; repoDir: string; templatesDir: string },
): Promise<void> {
  try {
    await runner(opts);
  } catch (error) {
    if (error instanceof StructuredOutputError) {
      console.error(`[${name}] Failed: malformed agent output`);
      console.error(`[${name}] Tag: <${error.tag}>`);
      console.error(`[${name}] Raw matched: ${error.rawMatched ?? "(no match found)"}`);
      if (error.cause) console.error(`[${name}] Cause:`, error.cause);
      process.exitCode = 1;
      return;
    }
    throw error;
  }
}

function parseRequiredPositiveInt(value: string | undefined, flag: string): number {
  if (!value) throw new Error(`address-review requires ${flag} <number>`);
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return parsed;
}
