import path from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { Output, StructuredOutputError, claudeCode } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { ImplementPrOutput } from "../schemas/implement-pr-output.js";
import { fetchPrComments } from "../lib/fetch-pr-comments.js";
import { postReview } from "../lib/post-review.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { runWithExtraction } from "../lib/run-with-extraction.js";
import { resolveDefaultExtractionsDir, resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });
const defaultExtractionsDir = resolveDefaultExtractionsDir({ workflowDir: __dirname });

export async function runImplementPr(opts: { prNumber: string; repoDir: string; model?: string; templatesDir?: string; extractionsDir?: string }): Promise<void> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const { prNumber, repoDir } = opts;
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;
  const extractionsDir = opts.extractionsDir ?? defaultExtractionsDir;

  console.log(`[implement-pr] Fetching PR #${prNumber} data...`);
  const prContext = fetchPrComments({ prNumber, cwd: repoDir });

  const branch = execFileSync("gh", ["pr", "view", prNumber, "--json", "headRefName", "--jq", ".headRefName"], {
    encoding: "utf8",
    cwd: repoDir,
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();

  const issueNumber = prContext.issueNumber || "(none)";
  const issueTitle = prContext.issueTitle || "(no linked issue)";

  console.log(`[implement-pr] PR: ${prContext.prTitle}`);
  console.log(`[implement-pr] Branch: ${branch}`);
  console.log(`[implement-pr] Linked issue: ${issueNumber === "(none)" ? "none" : `#${issueNumber} — ${issueTitle}`}`);
  console.log(`[implement-pr] Unresolved threads: ${prContext.comments.review_threads.length}`);

  try {
    const promptFile = await resolvePrompt({ name: "implement-pr", config, repoDir, templatesDir });

    const extractionPrompt = readFileSync(
      path.join(extractionsDir, "implement-pr.md"),
      "utf8",
    );

    const result = await runWithExtraction({
      name: `implement-pr-${prNumber}`,
      agent: claudeCode(model),
      sandbox: noSandbox(),
      cwd: repoDir,
      promptFile,
      promptArgs: {
        ...configPromptArgs(config),
        PR_NUMBER: prNumber,
        BRANCH: branch,
        ISSUE_NUMBER: issueNumber,
        ISSUE_TITLE: issueTitle,
        PR_COMMENTS_JSON: JSON.stringify(prContext.comments, null, 2),
      },
      output: Output.object({ tag: "output", schema: ImplementPrOutput }),
      extractionPrompt,
      logging: { type: "stdout" },
    });

    const commitsThisRun = result.commits.length;
    const replyCount = result.output.threadReplies.length + result.output.newInlineComments.length + result.output.topLevelComments.length;

    if (commitsThisRun === 0 && replyCount === 0) {
      console.error(`[implement-pr] FAILED: Agent produced no commits and no replies`);
      process.exit(1);
    }

    // Keep a non-empty review body when there are inline comments but no top-level
    // comments, so the GitHub UI never shows a review with a blank summary.
    const topLevelBody = result.output.topLevelComments.map((c) => c.body).join("\n\n");
    const reviewBody =
      topLevelBody || (result.output.newInlineComments.length > 0 ? "Addressed review feedback." : undefined);

    const reviewResult = postReview({
      prNumber,
      cwd: repoDir,
      prComments: prContext.comments,
      inlineComments: result.output.newInlineComments,
      threadReplies: result.output.threadReplies,
      reviewBody,
      skipEmptyReview: true,
      logPrefix: "[implement-pr]",
    });

    console.log(`\n[implement-pr] Complete`);
    console.log(`  commits: ${commitsThisRun}`);
    console.log(`  thread replies: ${reviewResult.postedReplies}`);
    console.log(`  inline comments: ${reviewResult.postedInlineComments}`);
    console.log(`  top-level comments: ${result.output.topLevelComments.length}`);
  } catch (error) {
    if (error instanceof StructuredOutputError) {
      console.error(`[implement-pr] Failed: malformed agent output`);
      console.error(`[implement-pr] Tag: <${error.tag}>`);
      console.error(`[implement-pr] Raw matched: ${error.rawMatched ?? "(no match found)"}`);
      if (error.cause) console.error(`[implement-pr] Cause:`, error.cause);
      process.exit(1);
    }
    throw error;
  }
}
