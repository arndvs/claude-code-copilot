import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { run, claudeCode } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { fetchPrComments, getOwnerRepo } from "../lib/fetch-pr-comments.js";
import { scoreComment } from "../lib/score-comment.js";
import { deferToIssue } from "../lib/defer-to-issue.js";
import { postRoundSummary } from "../lib/round-summary.js";
import { requestCopilotReview } from "../lib/request-review.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { resolveThreads } from "../lib/resolve-threads.js";
import type { ScoredComment, Tier } from "../lib/types.js";
import { resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });

interface AddressReviewOpts {
  prNumber: string;
  round: number;
  maxRounds: number;
  repoDir: string;
  model?: string;
  templatesDir?: string;
}

interface AddressReviewResult {
  fixed: number;
  deferred: number;
  remaining: number;
  roundCapped: boolean;
  roundsRun: number;
}

interface CommentWithThread {
  scored: ScoredComment;
  threadId: string;
  commentId: string;
}

export async function runAddressReview(opts: AddressReviewOpts): Promise<AddressReviewResult> {
  if (opts.round > opts.maxRounds) {
    throw new Error(`Invalid address-review round range: round (${opts.round}) must be less than or equal to maxRounds (${opts.maxRounds})`);
  }

  let totalFixed = 0;
  let totalDeferred = 0;
  let latestRemaining = 0;
  let latestRoundCapped = false;
  let roundsRun = 0;

  for (let currentRound = opts.round; currentRound <= opts.maxRounds; currentRound++) {
    const result = await runAddressReviewRound({ ...opts, round: currentRound });
    roundsRun++;
    totalFixed += result.fixed;
    totalDeferred += result.deferred;
    latestRemaining = result.remaining;
    latestRoundCapped = result.roundCapped;

    if (result.roundCapped || result.remaining === 0) {
      break;
    }
  }

  if (!latestRoundCapped && (totalFixed > 0 || totalDeferred > 0)) {
    const { owner, repo } = getOwnerRepo({ cwd: opts.repoDir });
    requestCopilotReview({ owner, repo, prNumber: opts.prNumber, cwd: opts.repoDir });
  }

  return { fixed: totalFixed, deferred: totalDeferred, remaining: latestRemaining, roundCapped: latestRoundCapped, roundsRun };
}

async function runAddressReviewRound(opts: AddressReviewOpts): Promise<Omit<AddressReviewResult, "roundsRun">> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const { prNumber, round, maxRounds, repoDir } = opts;
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;
  const { owner, repo } = getOwnerRepo({ cwd: repoDir });

  console.log(`\n[address-review] Round ${round}/${maxRounds} — PR #${prNumber}`);

  // 1. Fetch unresolved review threads
  console.log(`[address-review] Fetching unresolved threads...`);
  const prContext = fetchPrComments({ prNumber, cwd: repoDir });
  const threads = prContext.comments.review_threads;

  if (threads.length === 0) {
    console.log(`[address-review] No unresolved threads — nothing to do`);
    return { fixed: 0, deferred: 0, remaining: 0, roundCapped: false };
  }

  console.log(`[address-review] ${threads.length} unresolved thread(s)`);

  // 2. Score each comment
  const withThreads: CommentWithThread[] = threads.map((t) => ({
    scored: scoreComment({ path: t.path, line: t.line, body: t.body }),
    threadId: t.threadId,
    commentId: t.commentId,
  }));

  for (const { scored } of withThreads) {
    const signalNames = scored.signals.map((s) => s.label).join(", ");
    console.log(`[address-review]   score=${scored.score} tier=${scored.tier} signals=[${signalNames}]`);
  }

  // 3. Partition: Auto/Confirm vs HITL
  const autoConfirm = withThreads.filter((c) => c.scored.tier === "auto" || c.scored.tier === "confirm");
  const hitl = withThreads.filter((c) => c.scored.tier === "hitl");

  console.log(`[address-review] ${autoConfirm.length} auto/confirm, ${hitl.length} HITL`);

  // Track results for round summary
  const results: Array<{ body: string; score: number; tier: Tier; action: "fixed" | "deferred" | "skipped"; issueNumber?: number }> = [];

  // 4. For Auto/Confirm: fix via Sandcastle
  let fixedCount = 0;

  if (autoConfirm.length > 0) {
    console.log(`[address-review] Fixing ${autoConfirm.length} auto/confirm comment(s) via Sandcastle...`);

    const commentsPayload = autoConfirm.map((c) => ({
      path: c.scored.comment.path,
      line: c.scored.comment.line,
      body: c.scored.comment.body,
      score: c.scored.score,
      tier: c.scored.tier,
    }));

    try {
      const promptFile = await resolvePrompt({ name: "address-review", config, repoDir, templatesDir });

      const fixRun = await run({
        agent: claudeCode(model),
        sandbox: noSandbox(),
        cwd: repoDir,
        promptFile,
        promptArgs: {
          ...configPromptArgs(config),
          PR_NUMBER: prNumber,
          BRANCH: getBranch({ prNumber, cwd: repoDir }),
          COMMENTS_JSON: JSON.stringify(commentsPayload, null, 2),
        },
        completionSignal: "<promise>COMPLETE</promise>",
        logging: { type: "stdout" },
      });

      const touchedFiles = collectTouchedFiles({ runResult: fixRun, cwd: repoDir });
      const touchedComments = autoConfirm.filter((c) => c.scored.comment.path && touchedFiles.has(c.scored.comment.path));
      if (touchedComments.length > 0) {
        resolveThreads({ threadIds: touchedComments.map((c) => c.threadId), cwd: repoDir });
      }
      const unresolvedAfterResolution = new Set(fetchPrComments({ prNumber, cwd: repoDir }).comments.review_threads.map((thread) => thread.commentId));
      for (const c of autoConfirm) {
        if (c.scored.comment.path && touchedFiles.has(c.scored.comment.path) && !unresolvedAfterResolution.has(c.commentId)) {
          fixedCount++;
          results.push({ body: c.scored.comment.body, score: c.scored.score, tier: c.scored.tier, action: "fixed" });
        } else {
          results.push({ body: c.scored.comment.body, score: c.scored.score, tier: c.scored.tier, action: "skipped" });
        }
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[address-review] Sandcastle fix failed: ${message}`);

      // Mark all as skipped on failure
      for (const c of autoConfirm) {
        results.push({ body: c.scored.comment.body, score: c.scored.score, tier: c.scored.tier, action: "skipped" });
      }
    }
  }

  // 5. For HITL: defer to issues
  let deferredCount = 0;

  for (const c of hitl) {
    try {
      const result = deferToIssue({
        scored: c.scored,
        pr: { prNumber, owner, repo },
        threadId: c.threadId,
        cwd: repoDir,
      });
      deferredCount++;
      results.push({ body: c.scored.comment.body, score: c.scored.score, tier: c.scored.tier, action: "deferred", issueNumber: result.issueNumber });
      console.log(`[address-review] Deferred to #${result.issueNumber}: ${c.scored.comment.body.slice(0, 50)}`);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`[address-review] Failed to defer comment: ${message}`);
      results.push({ body: c.scored.comment.body, score: c.scored.score, tier: c.scored.tier, action: "skipped" });
    }
  }

  // 6. Post round summary
  postRoundSummary({ owner, repo, prNumber, round, maxRounds, results, cwd: repoDir });

  const remaining = results.filter((r) => r.action === "skipped").length;
  const roundCapped = round >= maxRounds && remaining > 0;

  console.log(`\n[address-review] Round ${round} complete`);
  console.log(`  fixed: ${fixedCount}`);
  console.log(`  deferred: ${deferredCount}`);
  console.log(`  remaining: ${remaining}`);
  if (roundCapped) {
    console.log(`  ⚠️ Round cap reached with ${remaining} unresolved comment(s)`);
  }

  return { fixed: fixedCount, deferred: deferredCount, remaining, roundCapped };
}

function getBranch(opts: { prNumber: string; cwd: string }): string {
  return execFileSync("gh", ["pr", "view", opts.prNumber, "--json", "headRefName", "--jq", ".headRefName"], {
    encoding: "utf8",
    cwd: opts.cwd,
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

interface AgentCommit {
  sha?: string;
  files?: string[];
}

interface AgentRunResult {
  commits?: AgentCommit[];
}

function collectTouchedFiles(opts: { runResult: unknown; cwd: string }): Set<string> {
  const files = new Set<string>();
  const commits = getAgentCommits(opts.runResult);

  for (const commit of commits) {
    for (const file of commit.files ?? []) {
      files.add(file);
    }

    if (!commit.sha) {
      continue;
    }

    for (const file of changedFilesForCommit({ sha: commit.sha, cwd: opts.cwd })) {
      files.add(file);
    }
  }

  return files;
}

function getAgentCommits(runResult: unknown): AgentCommit[] {
  if (typeof runResult !== "object" || runResult === null || !("commits" in runResult)) {
    return [];
  }

  const commits = (runResult as AgentRunResult).commits;
  return Array.isArray(commits) ? commits : [];
}

function changedFilesForCommit(opts: { sha: string; cwd: string }): string[] {
  try {
    const output = execFileSync("git", ["diff-tree", "--no-commit-id", "--name-only", "-r", opts.sha], {
      encoding: "utf8",
      cwd: opts.cwd,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return output.split(/\r?\n/).filter(Boolean);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`[address-review] Could not inspect changed files for ${opts.sha}: ${message}`);
    return [];
  }
}
