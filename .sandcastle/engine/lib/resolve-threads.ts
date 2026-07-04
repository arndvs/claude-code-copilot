import { shFile } from "./shell-helpers.js";

const RESOLVE_MUTATION = `
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}`;

/**
 * Resolve a single GitHub pull request review thread via GraphQL.
 *
 * Silently skips threads that are already resolved or where
 * the token lacks permission. Retries once on transient errors.
 */
export function resolveThread(opts: { threadId: string; cwd: string }): void {
  if (!opts.threadId.startsWith("PRRT_")) {
    throw new Error(`Invalid thread node ID (expected PRRT_ prefix): ${opts.threadId}`);
  }

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      shFile("gh", ["api", "graphql", "-F", `threadId=${opts.threadId}`, "-f", `query=${RESOLVE_MUTATION}`], opts.cwd);
      console.log(`Resolved thread ${opts.threadId}`);
      return;
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);

      // Already resolved — not an error
      if (message.includes("already resolved") || message.includes("ALREADY_RESOLVED")) {
        console.log(`Thread ${opts.threadId} already resolved, skipping`);
        return;
      }

      // Permission denied — warn and move on
      if (message.includes("403") || message.includes("FORBIDDEN") || message.includes("Resource not accessible")) {
        console.warn(`Permission denied resolving thread ${opts.threadId}, skipping`);
        return;
      }

      // First attempt failed with a transient error — retry
      if (attempt === 0) {
        console.warn(`Retrying thread resolution for ${opts.threadId}: ${message}`);
        continue;
      }

      // Second attempt also failed — warn and continue
      console.warn(`Failed to resolve thread ${opts.threadId} after 2 attempts: ${message}`);
      return;
    }
  }
}

/**
 * Resolve multiple review threads. Failures on individual threads
 * do not prevent resolution of remaining threads.
 */
export function resolveThreads(opts: { threadIds: string[]; cwd: string }): void {
  for (const threadId of opts.threadIds) {
    resolveThread({ threadId, cwd: opts.cwd });
  }
}
