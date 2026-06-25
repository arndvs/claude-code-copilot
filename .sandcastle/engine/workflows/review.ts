import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { Output, StructuredOutputError, claudeCode } from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { ReviewOutput } from "../schemas/review-output.js";
import { fetchPrComments } from "../lib/fetch-pr-comments.js";
import { parseDiffLineAnchors } from "../lib/parse-diff-lines.js";
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

  try {
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

    const headSha = execFileSync("gh", ["pr", "view", prNumber, "--json", "headRefOid", "--jq", ".headRefOid"], {
      encoding: "utf8",
      cwd: repoDir,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();

    const diffOutput = (() => {
      try {
        return execFileSync("gh", ["pr", "diff", prNumber], { encoding: "utf8", cwd: repoDir, stdio: ["ignore", "pipe", "pipe"] });
      } catch {
        return "";
      }
    })();
    const diffLines = parseDiffLineAnchors(diffOutput);

    const validInlineComments = result.output.inlineComments.filter((c) => {
      const fileLines = diffLines.get(c.path);
      if (!fileLines) {
        console.warn(`[review] Dropping inline comment for ${c.path}:${c.line} — file not in diff`);
        return false;
      }
      if (!fileLines[c.side].has(c.line)) {
        console.warn(`[review] Dropping inline comment for ${c.path}:${c.line} ${c.side} — line not in diff hunks`);
        return false;
      }
      return true;
    });

    const validReplyIds = new Set(prContext.comments.review_threads.map((c) => c.commentId));
    const threadIdByCommentId = new Map(prContext.comments.review_threads.map((c) => [c.commentId, c.threadId]));
    const validReplies = result.output.replies.filter((r) => {
      if (!validReplyIds.has(r.commentId)) {
        console.warn(`[review] Dropping reply for commentId=${r.commentId} — not in fetched threads`);
        return false;
      }
      return true;
    });

    const reviewPayload = JSON.stringify({
      commit_id: headSha,
      event: "COMMENT",
      body: result.output.summary,
      comments: validInlineComments.map((c) => ({ path: c.path, line: c.line, side: c.side, body: c.body })),
    });

    execFileSync("gh", ["api", `repos/{owner}/{repo}/pulls/${prNumber}/reviews`, "--input", "-"], {
      input: reviewPayload,
      encoding: "utf8",
      cwd: repoDir,
      stdio: ["pipe", "pipe", "pipe"],
    });
    console.log(`[review] Posted review with ${validInlineComments.length} inline comments`);

    for (const reply of validReplies) {
      const threadId = threadIdByCommentId.get(reply.commentId)!;
      console.log(`[review] Posting reply to thread ${threadId}...`);
      execFileSync(
        "gh",
        [
          "api", "graphql",
          "-F", `nodeId=${threadId}`,
          "-f", `body=${reply.body}`,
          "-f", "query=mutation($nodeId:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$nodeId,body:$body}){comment{id}}}",
        ],
        { cwd: repoDir, stdio: ["ignore", "pipe", "pipe"] },
      );
    }

    console.log(`\n[review] Complete`);
    console.log(`  summary: ${result.output.summary.slice(0, 80)}...`);
    console.log(`  inline comments: ${validInlineComments.length}`);
    console.log(`  thread replies: ${validReplies.length}`);
  } catch (error) {
    if (error instanceof StructuredOutputError) {
      console.error(`[review] Failed: malformed agent output`);
      console.error(`[review] Tag: <${error.tag}>`);
      console.error(`[review] Raw matched: ${error.rawMatched ?? "(no match found)"}`);
      if (error.cause) console.error(`[review] Cause:`, error.cause);
      process.exit(1);
    }
    throw error;
  }
}
