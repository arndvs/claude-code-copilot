import { shFile } from "./shell-helpers.js";

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
    const prJson = shFile("gh", ["pr", "view", prNumber, "--repo", `${owner}/${repo}`, "--json", "isDraft", "--jq", ".isDraft"], cwd).trim();

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
    // Use `gh pr edit --add-reviewer` (GraphQL requestReviews under the hood),
    // NOT the REST `/requested_reviewers` reviewers[] endpoint — the latter 422s
    // on the Copilot APP ("may only be requested from collaborators"), which made
    // this request silently no-op. The pr-auto-copilot-review workflow uses the
    // same mechanism for the same reason.
    shFile(
      "gh",
      ["pr", "edit", prNumber, "--repo", `${owner}/${repo}`, "--add-reviewer", "copilot-pull-request-reviewer"],
      cwd,
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
