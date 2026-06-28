import { execFileSync } from "node:child_process";
import { parseDiffLineAnchors } from "./parse-diff-lines.js";
import type { InlineComment } from "./inline-comment.js";
import type { PrComments } from "./fetch-pr-comments.js";

interface PostReviewOpts {
  prNumber: string;
  cwd: string;
  prComments: PrComments;
  inlineComments: InlineComment[];
  threadReplies: Array<{ commentId: string; body: string }>;
  reviewBody?: string;
  /** Skip posting the review when there are no inline comments and no review body. Defaults to true. */
  skipEmptyReview?: boolean;
  /** Logging prefix for console output (e.g. "[review]", "[implement-pr]") */
  logPrefix?: string;
}

export interface PostReviewResult {
  postedInlineComments: number;
  postedReplies: number;
  droppedComments: number;
  droppedReplies: number;
}

/**
 * Post a GitHub PR review with validated inline comments and thread replies.
 *
 * Handles:
 * - Fetching the PR head SHA and diff
 * - Parsing diff anchors
 * - Validating inline comments against the diff (drops invalid)
 * - Validating thread replies against known comment IDs (drops stale)
 * - POSTing the review via `gh api`
 * - POSTing thread replies via GraphQL
 */
export function postReview(opts: PostReviewOpts): PostReviewResult {
  const { prNumber, cwd, prComments, inlineComments, threadReplies, skipEmptyReview = true } = opts;
  const prefix = opts.logPrefix ?? "[post-review]";

  // Nothing to send: no inline comments, no thread replies, and an empty review is being
  // suppressed. Return before any gh round-trips to avoid latency and failure points.
  if (inlineComments.length === 0 && threadReplies.length === 0 && skipEmptyReview && !opts.reviewBody) {
    return { postedInlineComments: 0, postedReplies: 0, droppedComments: 0, droppedReplies: 0 };
  }

  // Only fetch + parse the PR diff when there are inline comments to validate against it.
  // Reply-only runs skip the gh pr diff round-trip entirely.
  const diffOutput =
    inlineComments.length > 0
      ? (() => {
          try {
            return execFileSync("gh", ["pr", "diff", prNumber], { encoding: "utf8", cwd, stdio: ["ignore", "pipe", "pipe"] });
          } catch {
            return "";
          }
        })()
      : "";
  const diffLines = parseDiffLineAnchors(diffOutput);

  const validInlineComments = inlineComments.filter((c) => {
    const fileLines = diffLines.get(c.path);
    if (!fileLines) {
      console.warn(`${prefix} Dropping inline comment for ${c.path}:${c.line} — file not in diff`);
      return false;
    }
    if (!fileLines[c.side].has(c.line)) {
      console.warn(`${prefix} Dropping inline comment for ${c.path}:${c.line} ${c.side} — line not in diff hunks`);
      return false;
    }
    return true;
  });

  const validReplyIds = new Set(prComments.review_threads.map((c) => c.commentId));
  const threadIdByCommentId = new Map(prComments.review_threads.map((c) => [c.commentId, c.threadId]));
  const validReplies = threadReplies.filter((r) => {
    if (!validReplyIds.has(r.commentId)) {
      console.warn(`${prefix} Dropping reply for commentId=${r.commentId} — not in fetched threads`);
      return false;
    }
    return true;
  });

  const droppedComments = inlineComments.length - validInlineComments.length;
  const droppedReplies = threadReplies.length - validReplies.length;

  // Compute the review body after validation so the fallback only appears when
  // at least one inline comment survived — avoids posting a placeholder-only review.
  const effectiveReviewBody =
    opts.reviewBody ?? (validInlineComments.length > 0 ? "Addressed review feedback." : undefined);

  if (skipEmptyReview && validInlineComments.length === 0 && !effectiveReviewBody) {
    // No review to post — just do thread replies
  } else {
    // Fetch the head SHA only now that we know a review will actually be posted.
    const headSha = execFileSync("gh", ["pr", "view", prNumber, "--json", "headRefOid", "--jq", ".headRefOid"], {
      encoding: "utf8",
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    const reviewPayload = JSON.stringify({
      commit_id: headSha,
      event: "COMMENT",
      body: effectiveReviewBody ?? "",
      comments: validInlineComments.map((c) => ({ path: c.path, line: c.line, side: c.side, body: c.body })),
    });

    execFileSync("gh", ["api", `repos/{owner}/{repo}/pulls/${prNumber}/reviews`, "--input", "-"], {
      input: reviewPayload,
      encoding: "utf8",
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });
    console.log(`${prefix} Posted review with ${validInlineComments.length} inline comments`);
  }

  for (const reply of validReplies) {
    const threadId = threadIdByCommentId.get(reply.commentId)!;
    console.log(`${prefix} Posting reply to thread ${threadId}...`);
    postThreadReply({ threadId, body: reply.body, cwd });
  }

  return {
    postedInlineComments: validInlineComments.length,
    postedReplies: validReplies.length,
    droppedComments,
    droppedReplies,
  };
}

/**
 * Post a single reply to a GitHub PR review thread via GraphQL.
 */
export function postThreadReply(opts: { threadId: string; body: string; cwd: string }): void {
  const mutation = `mutation($nodeId:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$nodeId,body:$body}){comment{id}}}`;

  // Use --raw-field for every value so literal content is sent as-is. gh's -F/--field
  // applies magic type conversion and treats a leading "@" as a filename, so a reply body
  // like "@user thanks" must never go through it.
  execFileSync(
    "gh",
    ["api", "graphql", "--raw-field", `nodeId=${opts.threadId}`, "--raw-field", `body=${opts.body}`, "--raw-field", `query=${mutation}`],
    { encoding: "utf8", cwd: opts.cwd, stdio: ["ignore", "pipe", "pipe"] },
  );
}
