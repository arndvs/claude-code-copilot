import { execFileSync } from "node:child_process";

/**
 * Re-request a review from GitHub Copilot on a pull request.
 * This closes the loop: after fixes are committed and threads resolved,
 * Copilot re-evaluates the updated code.
 *
 * Skips silently when:
 * - The PR is a draft
 * - Copilot is not available as a reviewer
 * - API errors occur (logged but not thrown)
 */
export function requestCopilotReview(opts: { owner: string; repo: string; prNumber: string; cwd: string }): void {
  const { owner, repo, prNumber, cwd } = opts;

  // Check if PR is a draft
  try {
    const prJson = execFileSync("gh", ["pr", "view", prNumber, "--repo", `${owner}/${repo}`, "--json", "isDraft", "--jq", ".isDraft"], {
      encoding: "utf8",
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();

    if (prJson === "true") {
      console.log(`PR #${prNumber} is a draft — skipping Copilot review request`);
      return;
    }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`Failed to check PR draft status: ${message}`);
    // Continue — attempt the review request anyway
  }

  try {
    execFileSync(
      "gh",
      ["api", "--method", "POST", `repos/${owner}/${repo}/pulls/${prNumber}/requested_reviewers`, "-f", "reviewers[]=copilot-pull-request-reviewer"],
      { encoding: "utf8", cwd, stdio: ["ignore", "pipe", "pipe"] },
    );
    console.log(`Requested Copilot review on PR #${prNumber}`);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);

    if (message.includes("422") || message.includes("Reviews may only be requested from collaborators")) {
      console.warn(`Copilot not available as reviewer on PR #${prNumber}, skipping`);
      return;
    }

    console.warn(`Failed to request Copilot review on PR #${prNumber}: ${message}`);
  }
}
