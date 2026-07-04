import path from "node:path";
import { fileURLToPath } from "node:url";
import { Output, claudeCode } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { ReviewOutput } from "../schemas/review-output.js";
import { fetchPrComments } from "../lib/fetch-pr-comments.js";
import { postReview } from "../lib/post-review.js";
import { loadConfig } from "../lib/config.js";
import { resolvePrompt, configPromptArgs } from "../lib/resolve-prompt.js";
import { runWithRetry } from "../lib/run-with-retry.js";
import { resolveDefaultTemplatesDir } from "../lib/default-template-paths.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultTemplatesDir = resolveDefaultTemplatesDir({ workflowDir: __dirname });

export async function runReview(opts: { prNumber: string; repoDir: string; model?: string; templatesDir?: string }): Promise<void> {
  const config = await loadConfig({ cwd: opts.repoDir });
  const { prNumber, repoDir } = opts;
  const model = opts.model ?? config.model;
  const templatesDir = opts.templatesDir ?? defaultTemplatesDir;

  console.log(`[review] Fetching PR #${prNumber} data...`);
  const prContext = fetchPrComments({ prNumber, cwd: repoDir });

  console.log(`[review] PR: ${prContext.prTitle}`);
  console.log(`[review] Existing threads: ${prContext.comments.review_threads.length}`);

  const promptFile = await resolvePrompt({ name: "review", config, repoDir, templatesDir });

  const result = await runWithRetry({
    agent: claudeCode(model),
    sandbox: noSandbox(),
    cwd: repoDir,
    promptFile,
    promptArgs: {
      ...configPromptArgs(config),
      PR_NUMBER: prNumber,
      PR_COMMENTS_JSON: JSON.stringify(prContext.comments, null, 2),
    },
    output: Output.object({ tag: "output", schema: ReviewOutput }),
    logging: { type: "stdout" },
  });

  const reviewResult = postReview({
    prNumber,
    cwd: repoDir,
    prComments: prContext.comments,
    inlineComments: result.output.inlineComments,
    threadReplies: result.output.replies,
    reviewBody: result.output.summary,
    logPrefix: "[review]",
  });

  console.log(`\n[review] Complete`);
  console.log(`  summary: ${result.output.summary.slice(0, 80)}...`);
  console.log(`  inline comments: ${reviewResult.postedInlineComments}`);
  console.log(`  thread replies: ${reviewResult.postedReplies}`);
}
