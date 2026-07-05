import { z } from "zod";
import { sh, safeSh, shFile } from "./shell-helpers.js";

const PrView = z.object({
  title: z.string(),
  body: z.string().nullable().default(""),
  headRefOid: z.string(),
  comments: z.array(
    z.object({
      id: z.string().optional(),
      author: z.object({ login: z.string() }).nullable().optional(),
      body: z.string(),
      createdAt: z.string().optional(),
    }),
  ),
});

const ThreadsResponse = z.object({
  data: z.object({
    repository: z.object({
      pullRequest: z.object({
        reviewThreads: z.object({
          pageInfo: z.object({
            hasNextPage: z.boolean(),
            endCursor: z.string().nullable(),
          }),
          nodes: z.array(
            z.object({
              id: z.string(),
              isResolved: z.boolean(),
              isOutdated: z.boolean(),
              comments: z.object({
                nodes: z.array(
                  z.object({
                    id: z.string(),
                    path: z.string().nullable(),
                    line: z.number().nullable(),
                    originalLine: z.number().nullable(),
                    body: z.string(),
                    author: z.object({ login: z.string() }).nullable(),
                  }),
                ),
              }),
            }),
          ),
        }),
      }),
    }),
  }),
});

const ReviewsResponse = z.array(
  z.object({
    id: z.number(),
    user: z.object({ login: z.string() }).nullable(),
    body: z.string().nullable().default(""),
    state: z.string(),
    submitted_at: z.string().nullable().optional(),
  }),
);

export interface PrComments {
  issue_comments: Array<{ author: string; body: string; createdAt?: string }>;
  review_summaries: Array<{ author: string; state: string; body: string | null; submittedAt?: string | null }>;
  review_threads: Array<{ commentId: string; threadId: string; path: string | null; line: number | null; author: string; body: string }>;
}

export interface PrContext {
  prTitle: string;
  issueNumber: string;
  issueTitle: string;
  comments: PrComments;
}

const GRAPHQL_QUERY = `
query($owner:String!,$repo:String!,$number:Int!,$cursor:String) {
  repository(owner:$owner,name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:100,after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          comments(first:100) {
            nodes {
              id
              path
              line
              originalLine
              body
              author { login }
            }
          }
        }
      }
    }
  }
}`;

export function getOwnerRepo(opts: { cwd: string }): { owner: string; repo: string } {
  const remoteUrl = sh("gh repo view --json nameWithOwner --jq .nameWithOwner", opts.cwd).trim();

  const parts = remoteUrl.split("/");
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    throw new Error(`Cannot parse owner/repo from: ${remoteUrl}`);
  }
  return { owner: parts[0], repo: parts[1] };
}

export function fetchPrComments(opts: { prNumber: string; cwd: string }): PrContext {
  if (!/^\d+$/.test(opts.prNumber)) {
    throw new Error(`Invalid PR number: ${opts.prNumber}`);
  }
  const prViewJson = sh(`gh pr view ${opts.prNumber} --json title,body,headRefOid,comments`, opts.cwd);
  const prView = PrView.parse(JSON.parse(prViewJson));

  const issueMatch = prView.body?.match(/(?:closes|fixes|resolves)\s+#(\d+)/i);
  const issueNumber = issueMatch?.[1] ?? "";
  const issueTitle = issueNumber
    ? safeSh(`gh issue view ${issueNumber} --json title --jq .title`, opts.cwd).trim()
    : "";

  const reviewsJson = sh(`gh api --paginate repos/{owner}/{repo}/pulls/${opts.prNumber}/reviews`, opts.cwd);
  // --paginate concatenates pages: [a,b][c,d] → join into single array
  const reviews = ReviewsResponse.parse(JSON.parse(reviewsJson.trim().replace(/\]\s*\[/g, ",")));

  const { owner, repo } = getOwnerRepo({ cwd: opts.cwd });

  // Paginate GraphQL reviewThreads — collect all pages
  type ThreadNode = z.infer<typeof ThreadsResponse>["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"][number];
  const allThreadNodes: ThreadNode[] = [];
  let cursor: string | null = null;

  for (;;) {
    const args = [
      "api", "graphql",
      "-F", `owner=${owner}`,
      "-F", `repo=${repo}`,
      "-F", `number=${opts.prNumber}`,
      "-f", `query=${GRAPHQL_QUERY}`,
    ];
    if (cursor) {
      args.push("-F", `cursor=${cursor}`);
    }

    const threadsJson = shFile("gh", args, opts.cwd);
    const page = ThreadsResponse.parse(JSON.parse(threadsJson));
    const { nodes, pageInfo } = page.data.repository.pullRequest.reviewThreads;

    allThreadNodes.push(...nodes);

    if (!pageInfo.hasNextPage || !pageInfo.endCursor) break;
    cursor = pageInfo.endCursor;
  }

  const unresolvedThreads = allThreadNodes.filter((t) => !t.isResolved && !t.isOutdated);

  const comments: PrComments = {
    issue_comments: prView.comments.map((c) => ({
      author: c.author?.login ?? "unknown",
      body: c.body,
      createdAt: c.createdAt,
    })),
    review_summaries: reviews
      .filter((r) => r.body && r.body.trim().length > 0)
      .map((r) => ({
        author: r.user?.login ?? "unknown",
        state: r.state,
        body: r.body,
        submittedAt: r.submitted_at,
      })),
    review_threads: unresolvedThreads.flatMap((t) =>
      t.comments.nodes.map((c) => ({
        commentId: c.id,
        threadId: t.id,
        path: c.path,
        line: c.line ?? c.originalLine,
        author: c.author?.login ?? "unknown",
        body: c.body,
      })),
    ),
  };

  return { prTitle: prView.title, issueNumber, issueTitle, comments };
}
